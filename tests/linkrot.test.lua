-- linkrot tests. Run from the repo root: quarto pandoc lua path/to/qtest.lua
-- Broken links use the reserved .invalid domain, so no test needs the network.
local t = require("qtest")

-- Regression: fail-on-error printed "Build failed" but the render exited 0.
t.test("fail-on-error: a broken link fails the render and lands in output-file", function()
  local r = t.render("broken.qmd", "html", { read = { "report.txt" } })
  r:failed()
  local report = r.extra["report.txt"]
  t.ok(report, "report.txt was written")
  t.contains(report, "Broken links found: 1")
  t.contains(report, "https://linkrot-test.invalid/missing")
end)

-- Regression: a fractional timeout (2.5) crashed the curl command format.
t.test("without fail-on-error a broken link only warns; a fractional timeout works", function()
  local r = t.render("broken-warn.qmd", "html", { read = { "report.txt" } })
  r:succeeded()
  t.contains(r.extra["report.txt"] or "", "Broken links found: 1")
end)

-- Regression: URLs were pasted into the curl command unquoted.
t.test("a URL cannot run shell commands", function()
  local r = t.render("injection.qmd", "html")
  r:succeeded()
  for file in pairs(r.files) do
    t.ok(not file:find("pwned", 1, true), "a link URL ran a command and created " .. file)
  end
end)

-- Regression: a malformed entry such as "(unclosed" raised a Lua error that
-- stopped the render; it now warns once and is matched as plain text.
t.test("skip-patterns: matching URLs are not reported; a malformed entry warns and matches as text", function()
  local r = t.render("skip.qmd", "html", { read = { "report.txt" } })
  r:succeeded()
  t.contains(r.log, "skip-patterns entry '(unclosed' is not a valid Lua pattern")
  local report = r.extra["report.txt"] or ""
  t.contains(report, "Broken links found: 1")
  t.contains(report, "/missing")
  t.not_contains(report, "/skipped")
  t.not_contains(report, "(unclosed")
end)

t.test("report-scope: project writes one report that names each page above its broken links", function()
  local r = t.render("project", "html", { output = "project/a.html", read = { "project/report.txt" } })
  r:succeeded()
  local report = r.extra["project/report.txt"] or ""
  t.contains(report, "Documents checked: 2")
  t.in_order(report, { "Broken links in a.qmd:", "/from-a", "Broken links in b.qmd:", "/from-b" })
end)
