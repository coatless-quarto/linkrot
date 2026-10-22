-- ============================================================================
-- TYPES
-- ============================================================================

---@class LinkrotConfig
---@field fail_on_error boolean `fail-on-error`: stop the render with exit status 1 if a link is broken
---@field timeout number `timeout`: seconds to wait for each URL (curl's --max-time)
---@field user_agent string `user-agent`: User-Agent header sent with each request
---@field cache_results boolean `cache-results`: check each unique URL only once
---@field debug boolean `debug`: log each step to the console
---@field output_file string|nil `output-file`: also write the report to this file
---@field skip_patterns string[] `skip-patterns`: Lua patterns for URLs that are not checked

---@alias LinkrotOptionKind "boolean"|"number"|"string"|"list"

---@class LinkrotOption
---@field key string Key under `extensions.linkrot`
---@field field string Matching field in `LinkrotConfig`
---@field kind LinkrotOptionKind How the metadata value is read

---@class BrokenLink
---@field url string
---@field text string Link text
---@field status integer|string HTTP status code, or "unavailable" if there was no response

---@class CachedResult
---@field valid boolean
---@field status integer|string|nil HTTP status code, "unavailable", or nil for a skipped URL

---@class LinkrotState
---@field broken_links BrokenLink[] Broken links, in document order
---@field checked_urls table<string, CachedResult> Results by URL, if `cache-results` is on
---@field check_count integer Number of external links checked

---@class CurlTemplate
---@field command string Format string taking the timeout, user agent and URL
---@field quote fun(value: string): string Quotes a value for the platform's shell

-- ============================================================================
-- STATE AND CONFIGURATION
-- ============================================================================

---@type LinkrotState
local state = {
  broken_links = {},
  checked_urls = {},
  check_count = 0
}

--- Configuration from `extensions.linkrot`, filled in by `read_config`.
---@type LinkrotConfig
local config = {
  fail_on_error = false,
  timeout = 10,
  user_agent = "Quarto-Linkrot/1.0",
  cache_results = true,
  debug = false,
  output_file = nil,
  skip_patterns = {}
}

--- Options read from `extensions.linkrot`, in the order the debug log lists them.
---@type LinkrotOption[]
local options = {
  { key = "fail-on-error", field = "fail_on_error", kind = "boolean" },
  { key = "timeout",       field = "timeout",       kind = "number" },
  { key = "user-agent",    field = "user_agent",    kind = "string" },
  { key = "cache-results", field = "cache_results", kind = "boolean" },
  { key = "debug",         field = "debug",         kind = "boolean" },
  { key = "output-file",   field = "output_file",   kind = "string" },
  { key = "skip-patterns", field = "skip_patterns", kind = "list" }
}

--- curl command and quoting for each platform. The URL and user agent are
--- quoted so the shell passes them to curl literally.
---@type table<string, CurlTemplate>
local curl_templates = {
  windows = {
    command = 'curl.exe -s -o NUL -w "%%{http_code}" -L --max-time %g -A %s %s 2>NUL',
    quote = function(value)
      return '"' .. value:gsub('"', '""') .. '"'
    end
  },
  posix = {
    -- Single quotes stop $(...), backticks and variables; ' is written as '\''
    command = 'curl -s -o /dev/null -w "%%{http_code}" -L --max-time %g -A %s %s 2>/dev/null',
    quote = function(value)
      return "'" .. value:gsub("'", "'\\''") .. "'"
    end
  }
}

local curl = package.config:sub(1, 1) == "\\" and curl_templates.windows or curl_templates.posix

-- ============================================================================
-- LOGGING
-- ============================================================================

--- Log a debug message prefixed with "[linkrot]" if debug mode is enabled.
---@param message string
local function debug_log(message)
  if config.debug then
    quarto.log.output("[linkrot] " .. message)
  end
end

-- ============================================================================
-- CONFIGURATION LOADING
-- ============================================================================

--- Stringify a metadata value, ignoring values that are absent or blank.
---@param value any Metadata value
---@return string|nil text
local function read_text(value)
  if not value then
    return nil
  end
  local text = pandoc.utils.stringify(value)
  if text:match("%S") then
    return text
  end
  return nil
end

--- Readers for each option kind. Each returns nil to keep the default.
---@type table<LinkrotOptionKind, fun(value: any): any>
local readers = {
  -- Any value other than `false` turns the option on
  boolean = function(value)
    return value ~= false
  end,
  number = function(value)
    return tonumber(pandoc.utils.stringify(value))
  end,
  string = read_text,
  list = function(value)
    if type(value) ~= "table" then
      return nil
    end
    local items = {}
    for _, item in ipairs(value) do
      local text = read_text(item)
      if text then
        table.insert(items, text)
      end
    end
    return items
  end
}

--- Read `extensions.linkrot` from the document metadata into `config`.
---@param meta pandoc.Meta
local function read_config(meta)
  local extensions = meta.extensions
  local opts = type(extensions) == "table" and extensions.linkrot or nil
  if type(opts) ~= "table" then
    return
  end

  for _, option in ipairs(options) do
    local value = opts[option.key]
    if value ~= nil then
      local parsed = readers[option.kind](value)
      if parsed ~= nil then
        config[option.field] = parsed
      end
    end
  end

  debug_log("Configuration loaded:")
  for _, option in ipairs(options) do
    local value = config[option.field]
    if option.kind == "list" then
      value = #value .. " pattern(s)"
    elseif value == nil then
      value = "none"
    end
    debug_log("  " .. option.key .. ": " .. tostring(value))
  end
end

-- ============================================================================
-- URL CHECKING
-- ============================================================================

--- Check whether a URL matches any of the `skip-patterns`.
---@param url string
---@return boolean
local function should_skip_url(url)
  for _, pattern in ipairs(config.skip_patterns) do
    if string.match(url, pattern) then
      debug_log("Skipping URL (matches pattern '" .. pattern .. "'): " .. url)
      return true
    end
  end
  return false
end

--- Run curl on a URL and return the HTTP status code it reports.
---@param url string
---@return integer|nil status_code The status code, or nil if curl gave no output
local function run_curl(url)
  local cmd = string.format(curl.command, config.timeout, curl.quote(config.user_agent), curl.quote(url))
  debug_log("Executing command: " .. cmd)

  local status_code = nil
  local handle = io.popen(cmd)
  if handle then
    status_code = tonumber(handle:read("a"))
    handle:close()
  end

  debug_log("Curl response: " .. (status_code and tostring(status_code) or "no response"))
  return status_code
end

--- Request a URL. Status codes from 200 to 399 count as valid.
---@param url string
---@return boolean is_valid
---@return integer|string status The HTTP status code, or "unavailable" if there was no response
local function check_url_accessibility(url)
  local status_code = run_curl(url)

  if not status_code or status_code == 0 then
    debug_log("URL check failed (no valid response): " .. url)
    return false, "unavailable"
  end

  local is_valid = status_code >= 200 and status_code < 400
  debug_log("URL " .. url .. " is " .. (is_valid and "valid" or "broken") .. " (status: " .. status_code .. ")")

  return is_valid, status_code
end

--- Check one external link and record it if it is broken. A URL found in
--- the cache was counted and recorded the first time, so it is skipped.
---@param url string
---@param text string Link text
local function process_link(url, text)
  local cached = state.checked_urls[url]
  if cached then
    debug_log("Using cached result for: " .. url .. " (valid: " .. tostring(cached.valid) ..
      ", status: " .. tostring(cached.status) .. ")")
    return
  end

  ---@type boolean, integer|string|nil
  local is_valid, status = true, nil
  if not should_skip_url(url) then
    debug_log("Checking URL: " .. url)
    is_valid, status = check_url_accessibility(url)
  end

  if config.cache_results then
    state.checked_urls[url] = { valid = is_valid, status = status }
  end

  state.check_count = state.check_count + 1

  if not is_valid then
    debug_log("Adding to broken links: " .. url)
    table.insert(state.broken_links, { url = url, text = text, status = status })
  end
end

-- ============================================================================
-- REPORT
-- ============================================================================

--- Build the report: the totals, then each broken link or "All links are valid!".
---@return string[] lines
local function build_report()
  local broken = state.broken_links
  local report = {
    "",
    "=== Linkrot Results ===",
    string.format("Total external links checked: %d", state.check_count),
    string.format("Broken links found: %d", #broken)
  }

  if #broken > 0 then
    table.insert(report, "")
    table.insert(report, "Broken links:")
    for i, link in ipairs(broken) do
      table.insert(report, string.format("  %d. [%s] %s (Status: %s)",
        i, link.text, link.url, link.status))
    end
  else
    table.insert(report, "All links are valid!")
  end
  table.insert(report, "")

  return report
end

--- Write the report to a file, replacing its contents.
---@param report string[]
---@param filepath string
local function write_report_to_file(report, filepath)
  debug_log("Writing results to file: " .. filepath)

  local file, err = io.open(filepath, "w")
  if not file then
    quarto.log.output("Error: Could not write to file " .. filepath .. ": " .. tostring(err))
    debug_log("Failed to write results to file: " .. tostring(err))
    return
  end

  file:write(table.concat(report, "\n"), "\n")
  file:close()

  quarto.log.output("Results written to: " .. filepath)
  debug_log("Successfully wrote results to file")
end

-- ============================================================================
-- PANDOC FILTER FUNCTIONS
-- ============================================================================

--- Check a Link element if it points to an external http(s) URL.
---@param link pandoc.Link
local function check_link(link)
  local url = link.target

  if url:match("^https?://") then
    debug_log("Found external link: " .. url)
    process_link(url, pandoc.utils.stringify(link.content))
  else
    debug_log("Skipping non-external link: " .. url)
  end
end

--- Print the report, write it to `output-file` if set, and stop the render
--- if `fail-on-error` is on and a link is broken.
local function report_results()
  if state.check_count == 0 then
    debug_log("No external links found to check")
    return
  end

  debug_log("Generating results report...")
  local report = build_report()
  for _, line in ipairs(report) do
    quarto.log.output(line)
  end
  if config.output_file then
    write_report_to_file(report, config.output_file)
  end

  if #state.broken_links > 0 and config.fail_on_error then
    debug_log("Failing build due to broken links")
    quarto.log.error("Build failed: broken links detected")
    -- Quarto's error() only logs, so exit directly to fail the build
    os.exit(1)
  end
end

-- ============================================================================
-- FILTER EXPORT
-- ============================================================================

-- Configuration is read first, then every link is checked, then the report runs.
return {
  { Meta = read_config },
  { Link = check_link },
  { Pandoc = report_results }
}
