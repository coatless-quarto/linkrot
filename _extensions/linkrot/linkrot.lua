-- ============================================================================
-- TYPES
-- ============================================================================

---@alias LinkrotReportScope "document"|"project"

---@class LinkrotConfig
---@field fail_on_error boolean `fail-on-error`: stop the render with exit status 1 if a link is broken
---@field timeout number `timeout`: seconds to wait for each URL (curl's --max-time)
---@field user_agent string `user-agent`: User-Agent header sent with each request
---@field cache_results boolean `cache-results`: check each unique URL only once
---@field debug boolean `debug`: log each step to the console
---@field output_file string|nil `output-file`: also write the report to this file
---@field report_scope LinkrotReportScope `report-scope`: whether `output-file` reports on this document or on every document in the project
---@field skip_patterns string[] `skip-patterns`: Lua patterns for URLs that are not checked

---@alias LinkrotOptionKind "boolean"|"number"|"string"|"list"

---@class LinkrotOption
---@field key string Key under `extensions.linkrot`
---@field field string Matching field in `LinkrotConfig`
---@field kind LinkrotOptionKind How the metadata value is read
---@field choices? string[] Accepted values of a string option, in lower case

---@class BrokenLink
---@field url string
---@field text string Link text
---@field status integer|string HTTP status code, or "unavailable" if there was no response

---@class PageResult
---@field document string Input path relative to the project, or the file name outside a project
---@field checked integer Number of external links checked
---@field broken BrokenLink[] Broken links, in document order

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
  report_scope = "document",
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
  { key = "report-scope",  field = "report_scope",  kind = "string", choices = { "document", "project" } },
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
      if parsed ~= nil and option.choices then
        local choice = parsed:lower()
        parsed = nil
        for _, allowed in ipairs(option.choices) do
          if choice == allowed then
            parsed = choice
          end
        end
        if not parsed then
          quarto.log.warning("linkrot: " .. option.key .. " must be one of " ..
            table.concat(option.choices, ", ") .. ", not '" .. choice .. "'. Using '" ..
            tostring(config[option.field]) .. "'.")
        end
      end
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

--- The document's path relative to the project directory, or its file name
--- when it is not part of a project.
---@return string
local function document_name()
  local input = quarto.doc.input_file
  local project_dir = quarto.project and quarto.project.directory
  if project_dir then
    return (pandoc.path.make_relative(input, project_dir):gsub("\\", "/"))
  end
  return pandoc.path.filename(input)
end

--- Build a report: the totals, then the broken links of each document under a
--- heading naming it, or "All links are valid!". A project report also counts
--- the documents.
---@param pages PageResult[]
---@param is_project boolean
---@return string[] lines
local function build_report(pages, is_project)
  local checked, broken = 0, 0
  for _, page in ipairs(pages) do
    checked = checked + page.checked
    broken = broken + #page.broken
  end

  local report = { "", "=== Linkrot Results ===" }
  if is_project then
    table.insert(report, string.format("Documents checked: %d", #pages))
  end
  table.insert(report, string.format("Total external links checked: %d", checked))
  table.insert(report, string.format("Broken links found: %d", broken))

  if broken > 0 then
    for _, page in ipairs(pages) do
      if #page.broken > 0 then
        table.insert(report, "")
        table.insert(report, "Broken links in " .. page.document .. ":")
        for i, link in ipairs(page.broken) do
          table.insert(report, string.format("  %d. [%s] %s (Status: %s)",
            i, link.text, link.url, link.status))
        end
      end
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
-- PROJECT REPORT
-- ============================================================================

-- With `report-scope: project`, each document saves its results as JSON in
-- .quarto/linkrot/ under the project, one file per document, and then rebuilds
-- the combined report from all of them. Re-rendering one page replaces only
-- that page's file, and documents rendering at the same time never write the
-- same results file.

--- Write a file through a temporary file and a rename, so a reader never sees
--- it half written.
---@param path string
---@param contents string
---@return boolean ok
---@return string|nil err
local function write_file_atomic(path, contents)
  local tmp = path .. "." .. pandoc.utils.sha1(tostring({}) .. os.clock() .. os.time()):sub(1, 12) .. ".tmp"
  local file, err = io.open(tmp, "w")
  if not file then
    -- io.open names the temporary file; name the target instead
    return false, path .. ": " .. tostring(err):gsub("^.*: ", "")
  end
  file:write(contents)
  file:close()

  if not os.rename(tmp, path) then
    -- Windows cannot rename over an existing file
    os.remove(path)
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
      os.remove(tmp)
      return false, rename_err
    end
  end
  return true
end

--- Read every document's saved results, sorted by document. Results whose
--- document no longer exists are deleted.
---@param results_dir string
---@param project_dir string
---@return PageResult[]
local function read_project_results(results_dir, project_dir)
  ---@type PageResult[]
  local pages = {}
  for _, name in ipairs(pandoc.system.list_directory(results_dir)) do
    local path = pandoc.path.join({ results_dir, name })
    local file = name:match("%.json$") and io.open(path, "r")
    if file then
      local ok, page = pcall(quarto.json.decode, file:read("a"))
      file:close()
      if ok and type(page) == "table" and type(page.document) == "string"
        and type(page.checked) == "number" and type(page.broken) == "table" then
        local source = io.open(pandoc.path.join({ project_dir, page.document }), "r")
        if source then
          source:close()
          table.insert(pages, page)
        else
          debug_log("Dropping results for a document that no longer exists: " .. page.document)
          os.remove(path)
        end
      end
    end
  end
  table.sort(pages, function(a, b) return a.document < b.document end)
  return pages
end

--- Where the project report goes: `output-file`, relative to the project.
--- Quarto rewrites a project-level path that already exists so it is relative
--- to each document (`../linkrot-report.txt` for `posts/news.qmd`), so that
--- prefix is removed again.
---@param project_dir string
---@param output_file string
---@return string
local function project_report_path(project_dir, output_file)
  if pandoc.path.is_absolute(output_file) then
    return output_file
  end
  local path = output_file:gsub("\\", "/")
  local offset = quarto.project.offset
  if offset and offset ~= "." and offset ~= "" then
    local prefix = offset:gsub("\\", "/") .. "/"
    if path:sub(1, #prefix) == prefix then
      path = path:sub(#prefix + 1)
    end
  end
  return pandoc.path.join({ project_dir, path })
end

--- Save this document's results and rebuild the project report from the
--- results of every document.
---@param page PageResult
---@param project_dir string
---@param report_path string
---@return boolean ok
---@return string|nil err
local function update_project_report(page, project_dir, report_path)
  local results_dir = pandoc.path.join({ project_dir, ".quarto", "linkrot" })
  pandoc.system.make_directory(results_dir, true)
  local results_file = pandoc.path.join({ results_dir, pandoc.utils.sha1(page.document) .. ".json" })
  debug_log("Saving results for " .. page.document .. " to " .. results_file)
  local ok, err = write_file_atomic(results_file, quarto.json.encode(page))
  if not ok then
    return false, err
  end

  -- A document rendering at the same time may save its results while this one
  -- writes the report. Rebuild until the report matches the saved results.
  local text = table.concat(build_report(read_project_results(results_dir, project_dir), true), "\n") .. "\n"
  for _ = 1, 5 do
    ok, err = write_file_atomic(report_path, text)
    if not ok then
      return false, err
    end
    local latest = table.concat(build_report(read_project_results(results_dir, project_dir), true), "\n") .. "\n"
    if latest == text then
      return true
    end
    debug_log("Results changed while writing the project report; rebuilding it")
    text = latest
  end
  return true
end

--- The project directory if this render writes a project report, or nil.
---@return string|nil
local function project_report_directory()
  if config.report_scope ~= "project" then
    return nil
  end
  local project_dir = quarto.project and quarto.project.directory
  if not project_dir then
    quarto.log.warning("linkrot: report-scope: project needs a Quarto project; " ..
      "reporting on this document only.")
    return nil
  end
  if not config.output_file then
    quarto.log.warning("linkrot: report-scope: project needs output-file; " ..
      "no project report is written.")
    return nil
  end
  return project_dir
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

--- Print the report, write it to `output-file` or update the project report,
--- and stop the render if `fail-on-error` is on and a link is broken.
local function report_results()
  ---@type PageResult
  local page = { document = document_name(), checked = state.check_count, broken = state.broken_links }
  local project_dir = project_report_directory()

  if state.check_count > 0 then
    debug_log("Generating results report...")
    local report = build_report({ page }, false)
    for _, line in ipairs(report) do
      quarto.log.output(line)
    end
    if config.output_file and not project_dir then
      write_report_to_file(report, config.output_file)
    end
  else
    debug_log("No external links found to check")
  end

  -- A document without external links is saved too, so re-rendering a page
  -- whose broken links were removed clears them from the project report.
  if project_dir and config.output_file then
    local report_path = project_report_path(project_dir, config.output_file)
    -- pcall also catches errors raised by pandoc.system, such as a folder
    -- that cannot be created
    local ran, ok, err = pcall(update_project_report, page, project_dir, report_path)
    if ran and ok then
      quarto.log.output("Project results written to: " ..
        (pandoc.path.make_relative(report_path, project_dir):gsub("\\", "/")))
    else
      quarto.log.warning("linkrot: could not update the project report: " .. tostring(ran and err or ok))
    end
  end

  if #page.broken > 0 and config.fail_on_error then
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
