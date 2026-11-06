# linkrot <img src="docs/linkrot-animated-logo.svg" align ="right" alt="" width ="150"/>

A Quarto extension that automatically checks for broken external links in your documents during rendering.

## Installation

To install the `linkrot` Quarto extension, follow these steps:

1. Open your terminal.
2. Execute the following command:

```sh
quarto add coatless-quarto/linkrot
```

This command will download and install the Quarto extension under the `_extensions` subdirectory of your Quarto project.
If you are using version control, ensure that you include this directory in your repository.

### Requirements

- Quarto >= 1.11.0
- `curl` command-line tool:
  - **Linux/macOS**: Usually pre-installed
  - **Windows**: Built-in on Windows 10 (1803+) and Windows 11
  - **Older Windows**: Install [curl for Windows](https://curl.se/windows/) or use Git Bash which includes curl

## Usage

Add the extension to your document's YAML header:

```yaml
---
title: "My Document"
filters:
  - linkrot
---
```

The extension will automatically check all external HTTP/HTTPS links during rendering and report any broken links.

## Configuration

You can configure linkrot's behavior in your document's YAML using the `extensions.linkrot` key:

```yaml
---
title: "My Document"
filters:
  - linkrot
extensions:
  linkrot:
    fail-on-error: false      # Set to true to fail the build if broken links are found
    timeout: 10               # Timeout in seconds for each URL check
    user-agent: "Quarto-Linkrot/1.0"  # User agent string for requests
    cache-results: true       # Cache results to avoid checking the same URL multiple times
    debug: false              # Enable debug logging
    output-file: null         # Write results to a file (e.g., "linkrot-report.txt")
    report-scope: document    # Set to project for one report covering every page
    skip-patterns:            # List of Lua patterns to skip
      - "example%.com"
      - "localhost"
---
```

### Configuration Options

#### fail-on-error (default: `false`)

- If set to `true`, the build will fail if any broken links are detected. Useful for CI/CD pipelines.

#### timeout (default: `10`)

- Maximum time in seconds to wait for each URL to respond.

#### user-agent (default: `"Quarto-Linkrot/1.0"`)

- User agent string sent with HTTP requests.

#### cache-results (default: `true`)

- Cache URL check results to avoid repeatedly checking the same URL in a document.

#### debug (default: `false`)

- Enable debug logging to see detailed information about what linkrot is doing.

#### output-file (default: `null`)

- Path to a file where results will be written. If not specified, results are only shown in the console.

#### report-scope (default: `"document"`)

- `document`: `output-file` holds this document's report. In a project, each document replaces the file with its own report.
- `project`: `output-file` holds one report for every document in the project, grouped by page. The path is relative to the project directory.
- With `project`, linkrot keeps each page's results in `.quarto/linkrot/`, so re-rendering one page, for example in `quarto preview`, updates only that page's entry. Delete that folder to start the report over.

#### skip-patterns

- List of [Lua patterns](https://www.lua.org/manual/5.4/manual.html#6.4.1), not regular expressions. URLs matching any pattern will be skipped (not checked).
- Escape special characters such as `.` and `-` with `%`, as in `example%.com`. A backslash does not work: metadata is read as Markdown, so `example\\.com` reaches linkrot as `example.com`.
- An entry that isn't a valid Lua pattern, such as `[`, gets a warning and is matched as plain text.

## Example Output

When the extension runs, you'll see output like this in the console:

```default
=== Linkrot Results ===
Total external links checked: 15
Broken links found: 2

Broken links in my-document.qmd:
  1. [Example Link] https://example.com/broken-page (Status: 404)
  2. [Another Link] https://nonexistent-site-xyz123.com (Status: unavailable)
```

You can also specify an output file to save the results.
With `report-scope: project`, that file lists the broken links of every page in the project:

```default
=== Linkrot Results ===
Documents checked: 3
Total external links checked: 5
Broken links found: 3

Broken links in guide.qmd:
  1. [install page] https://example.com/old/install (Status: 404)
  2. [mirror] https://mirror.example.org/ (Status: unavailable)

Broken links in posts/news.qmd:
  1. [announcement] https://example.com/news/2024 (Status: 404)
```

## Learn more

- [Documentation](https://quarto.thecoatlessprofessor.com/linkrot/)
- [Release notes](https://quarto.thecoatlessprofessor.com/linkrot/qlinkrot-release-notes.html)
- [Blog posts](https://blog.thecoatlessprofessor.com/projects/linkrot/)

## License

linkrot is licensed under AGPL-3.0-or-later with an exception: what you write and render with linkrot stays yours, along with the output, under any terms you like. See [LICENSE](LICENSE) and [LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md).
