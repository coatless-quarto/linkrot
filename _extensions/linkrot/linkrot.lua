-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

--- State container for link checking process.
-- @class table
-- @name state
-- @field broken_links Array of broken link records
-- @field checked_urls Cache of URL check results
-- @field check_count Total number of external links checked
-- @field broken_count Number of broken links found
local state = {
  broken_links = {},
  checked_urls = {},
  check_count = 0,
  broken_count = 0
}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

--- Configuration options with defaults.
-- @class table
-- @name config
-- @field fail_on_error Whether to fail build if broken links are found
-- @field timeout Timeout in seconds for HTTP requests
-- @field user_agent User agent string for HTTP requests
-- @field skip_patterns Array of regex patterns for URLs to skip
-- @field cache_results Whether to cache URL check results
-- @field debug Enable debug logging
-- @field output_file Optional file path for report output
local config = {
  fail_on_error = false,
  timeout = 10,
  user_agent = "Quarto-Linkrot/1.0",
  skip_patterns = {},
  cache_results = true,
  debug = false,
  output_file = nil
}

-- ============================================================================
-- LOGGING UTILITIES
-- ============================================================================

--- Log a debug message if debug mode is enabled.
-- Messages are prefixed with "[linkrot]" and output via quarto.log.output().
-- @param message The message to log
-- @usage debug_log("Checking URL: " .. url)
local function debug_log(message)
  if config.debug then
    quarto.log.output("[linkrot] " .. message)
  end
end

--- Log all configuration values for debugging.
-- Outputs fail-on-error, timeout, user-agent, cache-results, debug,
-- output-file, and skip-patterns count.
-- @see config
local function log_configuration()
  debug_log("Configuration loaded:")
  debug_log("  fail-on-error: " .. tostring(config.fail_on_error))
  debug_log("  timeout: " .. tostring(config.timeout))
  debug_log("  user-agent: " .. config.user_agent)
  debug_log("  cache-results: " .. tostring(config.cache_results))
  debug_log("  debug: " .. tostring(config.debug))
  debug_log("  output-file: " .. tostring(config.output_file or "none"))
  debug_log("  skip-patterns: " .. #config.skip_patterns .. " pattern(s)")
end

-- ============================================================================
-- PLATFORM DETECTION
-- ============================================================================

--- Detect if running on Windows operating system.
-- Uses package.config to determine directory separator.
-- @return true if Windows, false otherwise
local function is_windows()
  return package.config:sub(1,1) == '\\'
end

-- ============================================================================
-- URL UTILITIES
-- ============================================================================

--- Check if a URL is external (http or https).
-- @param url The URL to check
-- @return true if URL starts with http:// or https://, false otherwise
-- @usage if is_external_link(url) then check_url(url) end
local function is_external_link(url)
  return url:match("^https?://") ~= nil
end

--- Check if a URL should be skipped based on configured patterns.
-- Matches the URL against all patterns in config.skip_patterns.
-- @param url The URL to check
-- @return true if URL matches any skip pattern, false otherwise
-- @see config.skip_patterns
local function should_skip_url(url)
  for _, pattern in ipairs(config.skip_patterns) do
    if string.match(url, pattern) then
      debug_log("Skipping URL (matches pattern '" .. pattern .. "'): " .. url)
      return true
    end
  end
  return false
end

--- Get cached result for a URL if caching is enabled.
-- @param url The URL to look up
-- @return cached_result The cached validation result (true/false), or nil if not cached
-- @return was_cached true if result was found in cache, false otherwise
-- @see state.checked_urls
local function get_cached_result(url)
  if config.cache_results and state.checked_urls[url] ~= nil then
    debug_log("Using cached result for: " .. url .. " (valid: " .. tostring(state.checked_urls[url]) .. ")")
    return state.checked_urls[url], true
  end
  return nil, false
end

--- Cache the result of a URL check.
-- Only caches if config.cache_results is true.
-- @param url The URL that was checked
-- @param is_valid Whether the URL is valid (true) or broken (false)
-- @see state.checked_urls
-- @see config.cache_results
local function cache_result(url, is_valid)
  if config.cache_results then
    state.checked_urls[url] = is_valid
  end
end

-- ============================================================================
-- CURL COMMAND GENERATION
-- ============================================================================

--- Build curl command for Windows platform.
-- Uses curl.exe with Windows-specific paths and escaping.
-- @param url The URL to check
-- @return The complete curl command string for Windows
-- @see config.timeout
-- @see config.user_agent
local function build_windows_curl_command(url)
  local escaped_url = url:gsub('"', '""')
  return string.format(
    'curl.exe -s -o NUL -w "%%%%{http_code}" -L --max-time %d -A "%s" "%s" 2>NUL',
    config.timeout,
    config.user_agent,
    escaped_url
  )
end

--- Build curl command for Unix/Linux/macOS platforms.
-- Uses standard curl with Unix-specific paths and escaping.
-- @param url The URL to check
-- @return The complete curl command string for Unix-like systems
-- @see config.timeout
-- @see config.user_agent
local function build_unix_curl_command(url)
  return string.format(
    'curl -s -o /dev/null -w "%%{http_code}" -L --max-time %d -A "%s" "%s" 2>/dev/null',
    config.timeout,
    config.user_agent,
    url:gsub('"', '\\"')
  )
end

--- Build appropriate curl command for the current platform.
-- Automatically detects the platform and calls the appropriate builder.
-- @param url The URL to check
-- @return The complete curl command string for the current platform
-- @see build_windows_curl_command
-- @see build_unix_curl_command
-- @see is_windows
local function build_curl_command(url)
  if is_windows() then
    return build_windows_curl_command(url)
  else
    return build_unix_curl_command(url)
  end
end

-- ============================================================================
-- URL CHECKING
-- ============================================================================

--- Execute curl command and extract HTTP status code.
-- @param cmd The curl command to execute
-- @return The HTTP status code as a number, or nil if curl failed
local function execute_curl(cmd)
  debug_log("Executing command: " .. cmd)
  
  local handle = io.popen(cmd)
  local result = handle:read("*a")
  local success = handle:close()
  
  local status_code = tonumber(result)
  debug_log("Curl response: " .. (status_code and tostring(status_code) or "no response"))
  
  return status_code
end

--- Validate HTTP status code.
-- Status codes in the 2xx and 3xx ranges are considered valid.
-- @param status_code The HTTP status code to validate
-- @return true if status code indicates success (200-399), false otherwise
local function is_valid_status_code(status_code)
  return status_code and status_code >= 200 and status_code < 400
end

--- Check if a URL is accessible via HTTP request.
-- Builds and executes a curl command, then validates the response.
-- @param url The URL to check
-- @return is_valid true if URL is accessible, false if broken
-- @return status_code The HTTP status code, or "unavailable" if request failed
-- @see build_curl_command
-- @see execute_curl
-- @see is_valid_status_code
local function check_url_accessibility(url)
  local cmd = build_curl_command(url)
  local status_code = execute_curl(cmd)
  
  if not status_code or status_code == 0 then
    debug_log("URL check failed (no valid response): " .. url)
    return false, "unavailable"
  end
  
  local is_valid = is_valid_status_code(status_code)
  debug_log("URL " .. url .. " is " .. (is_valid and "valid" or "broken") .. " (status: " .. status_code .. ")")
  
  return is_valid, status_code
end

--- Main URL checking function with caching and skip logic.
-- Checks cache first, then skip patterns, then performs actual HTTP check.
-- Results are cached if caching is enabled.
-- @param url The URL to check
-- @return is_valid true if URL is valid or skipped, false if broken
-- @return status_code The HTTP status code, or nil if cached/skipped
-- @see get_cached_result
-- @see should_skip_url
-- @see check_url_accessibility
-- @see cache_result
-- @usage local is_valid, status = check_url("https://example.com")
local function check_url(url)
  -- Check cache first
  local cached_result, was_cached = get_cached_result(url)
  if was_cached then
    return cached_result
  end
  
  -- Check if we should skip this URL
  if should_skip_url(url) then
    cache_result(url, true)
    return true
  end
  
  debug_log("Checking URL: " .. url)
  
  -- Perform actual check
  local is_valid, status_code = check_url_accessibility(url)
  
  -- Cache the result
  cache_result(url, is_valid)
  
  return is_valid, status_code
end

-- ============================================================================
-- LINK TRACKING
-- ============================================================================

--- Record a broken link in the state.
-- Increments broken_count and adds link details to broken_links array.
-- @param url The broken URL
-- @param text The link text/anchor text
-- @param status The HTTP status code or error message
-- @see state.broken_links
-- @see state.broken_count
local function add_broken_link(url, text, status)
  state.broken_count = state.broken_count + 1
  debug_log("Adding to broken links: " .. url)
  
  table.insert(state.broken_links, {
    url = url,
    text = text,
    status = status or "timeout/error"
  })
end

--- Process and check a single link.
-- Increments check_count, validates the URL, and records if broken.
-- @param url The URL to check
-- @param link_text The anchor text of the link
-- @see check_url
-- @see add_broken_link
-- @see state.check_count
local function process_link(url, link_text)
  state.check_count = state.check_count + 1
  
  local is_valid, status_code = check_url(url)
  
  if not is_valid then
    add_broken_link(url, link_text, status_code)
  end
end

-- ============================================================================
-- REPORT GENERATION
-- ============================================================================

--- Build the report header with statistics.
-- @return Array of header lines
-- @see state.check_count
-- @see state.broken_count
local function build_report_header()
  local header = {}
  table.insert(header, "")
  table.insert(header, "=== Linkrot Results ===")
  table.insert(header, string.format("Total external links checked: %d", state.check_count))
  table.insert(header, string.format("Broken links found: %d", state.broken_count))
  return header
end

--- Build the broken links section of the report.
-- Lists all broken links with their text and status codes.
-- @return Array of report lines for broken links section
-- @see state.broken_links
-- @see state.broken_count
local function build_broken_links_section()
  local section = {}
  
  if state.broken_count > 0 then
    table.insert(section, "")
    table.insert(section, "Broken links:")
    for i, link in ipairs(state.broken_links) do
      table.insert(section, string.format("  %d. [%s] %s (Status: %s)", 
        i, link.text, link.url, link.status))
    end
    table.insert(section, "")
  else
    table.insert(section, "All links are valid!")
    table.insert(section, "")
  end
  
  return section
end

--- Build the complete linkrot report.
-- Combines header and broken links sections.
-- @return Array of all report lines
-- @see build_report_header
-- @see build_broken_links_section
local function build_report()
  local report = {}
  
  -- Add header
  for _, line in ipairs(build_report_header()) do
    table.insert(report, line)
  end
  
  -- Add broken links section
  for _, line in ipairs(build_broken_links_section()) do
    table.insert(report, line)
  end
  
  return report
end

-- ============================================================================
-- OUTPUT HANDLING
-- ============================================================================

--- Output report to console using quarto.log.output().
-- @param report Array of report lines to output
local function output_to_console(report)
  for _, line in ipairs(report) do
    quarto.log.output(line)
  end
end

--- Write report to a file.
-- Creates or overwrites the specified file with the report contents.
-- @param report Array of report lines to write
-- @param filepath Path to the output file
-- @return true if successful, false if file could not be written
local function write_report_to_file(report, filepath)
  debug_log("Writing results to file: " .. filepath)
  
  local file, err = io.open(filepath, "w")
  if not file then
    quarto.log.output("Error: Could not write to file " .. filepath .. ": " .. tostring(err))
    debug_log("Failed to write results to file: " .. tostring(err))
    return false
  end
  
  for _, line in ipairs(report) do
    file:write(line .. "\n")
  end
  file:close()
  
  quarto.log.output("Results written to: " .. filepath)
  debug_log("Successfully wrote results to file")
  return true
end

--- Output report to all configured destinations.
-- Always outputs to console. If output_file is configured, also writes to file.
-- @param report Array of report lines to output
-- @see output_to_console
-- @see write_report_to_file
-- @see config.output_file
local function output_report(report)
  -- Always output to console
  output_to_console(report)
  
  -- Write to file if configured
  if config.output_file and config.output_file ~= "" then
    write_report_to_file(report, config.output_file)
  end
end

-- ============================================================================
-- BUILD CONTROL
-- ============================================================================

--- Handle build failure if configured.
-- Triggers a Lua error to fail the build if broken links were found
-- and fail_on_error is enabled.
-- @see state.broken_count
-- @see config.fail_on_error
local function handle_build_failure()
  if state.broken_count > 0 and config.fail_on_error then
    debug_log("Failing build due to broken links")
    error("Build failed: broken links detected")
  end
end

-- ============================================================================
-- CONFIGURATION LOADING
-- ============================================================================

--- Validate and parse a string value from metadata.
-- Returns nil if value is empty or contains only whitespace.
-- @param value The metadata value to parse
-- @return The parsed string, or nil if invalid/empty
local function parse_string_value(value)
  if not value then
    return nil
  end
  
  local str = pandoc.utils.stringify(value)
  -- Only return if not empty and contains non-whitespace
  if str and str:match("%S") then
    return str
  end
  
  return nil
end

--- Load fail-on-error configuration setting.
-- @param lr The linkrot configuration table from metadata
-- @see config.fail_on_error
local function load_fail_on_error(lr)
  if lr["fail-on-error"] ~= nil then
    config.fail_on_error = lr["fail-on-error"]
  end
end

--- Load timeout configuration setting.
-- Converts to number and validates before setting.
-- @param lr The linkrot configuration table from metadata
-- @see config.timeout
local function load_timeout(lr)
  if lr.timeout then
    local timeout = tonumber(pandoc.utils.stringify(lr.timeout))
    if timeout then
      config.timeout = timeout
    end
  end
end

--- Load user-agent configuration setting.
-- @param lr The linkrot configuration table from metadata
-- @see config.user_agent
local function load_user_agent(lr)
  if lr["user-agent"] then
    local user_agent = parse_string_value(lr["user-agent"])
    if user_agent then
      config.user_agent = user_agent
    end
  end
end

--- Load skip-patterns configuration setting.
-- Parses array of regex patterns for URLs to skip.
-- @param lr The linkrot configuration table from metadata
-- @see config.skip_patterns
local function load_skip_patterns(lr)
  if lr["skip-patterns"] then
    config.skip_patterns = {}
    for _, pattern in ipairs(lr["skip-patterns"]) do
      local pattern_str = parse_string_value(pattern)
      if pattern_str then
        table.insert(config.skip_patterns, pattern_str)
      end
    end
  end
end

--- Load cache-results configuration setting.
-- @param lr The linkrot configuration table from metadata
-- @see config.cache_results
local function load_cache_results(lr)
  if lr["cache-results"] ~= nil then
    config.cache_results = lr["cache-results"]
  end
end

--- Load debug configuration setting.
-- @param lr The linkrot configuration table from metadata
-- @see config.debug
local function load_debug(lr)
  if lr.debug ~= nil then
    config.debug = lr.debug
  end
end

--- Load output-file configuration setting.
-- Validates that the file path is not empty before setting.
-- @param lr The linkrot configuration table from metadata
-- @see config.output_file
local function load_output_file(lr)
  if lr["output-file"] then
    local output_file = parse_string_value(lr["output-file"])
    if output_file then
      config.output_file = output_file
    end
  end
end

--- Load all configuration options from metadata.
-- Orchestrates loading of all individual configuration settings.
-- @param lr The linkrot configuration table from metadata
-- @see load_fail_on_error
-- @see load_timeout
-- @see load_user_agent
-- @see load_skip_patterns
-- @see load_cache_results
-- @see load_debug
-- @see load_output_file
local function load_configuration(lr)
  load_fail_on_error(lr)
  load_timeout(lr)
  load_user_agent(lr)
  load_skip_patterns(lr)
  load_cache_results(lr)
  load_debug(lr)
  load_output_file(lr)
end

-- ============================================================================
-- PANDOC FILTER FUNCTIONS
-- ============================================================================

--- Process Link elements in the document.
-- Checks if link is external, and if so, validates it and tracks the result.
-- This function is called by Pandoc for each Link element in the AST.
-- @param el The Pandoc Link element
-- @return The unmodified Link element
-- @see is_external_link
-- @see process_link
function Link(el)
  local url = el.target
  
  if is_external_link(url) then
    debug_log("Found external link: " .. url)
    local link_text = pandoc.utils.stringify(el.content)
    process_link(url, link_text)
  else
    debug_log("Skipping non-external link: " .. url)
  end
  
  return el
end

--- Process document metadata and load configuration.
-- Reads configuration from extensions.linkrot key in metadata.
-- This function is called by Pandoc before processing the document.
-- @param meta The Pandoc Meta element containing document metadata
-- @return The unmodified Meta element
-- @see load_configuration
-- @see log_configuration
function Meta(meta)
  -- Read from extensions.linkrot path
  if meta.extensions and meta.extensions.linkrot then
    load_configuration(meta.extensions.linkrot)
    log_configuration()
  end
  
  return meta
end

--- Process complete document and generate final report.
-- Builds and outputs the report, handles file writing, and triggers
-- build failure if configured. This function is called by Pandoc after
-- all links have been processed.
-- @param doc The complete Pandoc document
-- @return The unmodified document
-- @see build_report
-- @see output_report
-- @see handle_build_failure
function Pandoc(doc)
  if state.check_count > 0 then
    debug_log("Generating results report...")
    
    local report = build_report()
    output_report(report)
    handle_build_failure()
  else
    debug_log("No external links found to check")
  end
  
  return doc
end

-- ============================================================================
-- FILTER EXPORT
-- ============================================================================

--- Export the filter functions to Pandoc.
-- The filters are executed in the order: Meta, Link, Pandoc.
-- @return Array of filter tables for Pandoc
return {
  { Meta = Meta },
  { Link = Link },
  { Pandoc = Pandoc }
}