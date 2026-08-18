# Windows screenshot export tool

- Added an explicit `save_screenshot` MCP tool for Windows so an AI can export the current app window without decoding an image content block.
- Registered the tool in the Windows MCP schema with required `app` and absolute `path` arguments, and clarified the behavior in server instructions.
- Completed base64 decoding and file writing in the Windows bridge.
- Added regression coverage for tool count, schema discovery, and relative-path rejection.

Validation completed:

- `go test .`: PASS
- `git diff --check`: PASS
- Direct MCP `list-tools`: PASS; `save_screenshot` is discoverable.
- Direct MCP smoke call against Edge: PASS; wrote a valid PNG to the user's Desktop.
