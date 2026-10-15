# image2 Plugin

This Codex desktop plugin packages the image2 skill, its PowerShell generation script, and a Windows configuration window.

## Configuration

Run `scripts/Configure.ps1` from the plugin folder. It edits `%USERPROFILE%\.codex\image2.env`, keeps unrecognized settings, masks the API key, and can test the relay's `/models` endpoint. The API key is stored locally in that file and is never included in this package.

`AUTO_GENERATE_ASSETS` is off by default. Enable it in the configuration window to let the skill generate missing bitmap assets during software development after project and external asset searches do not find a suitable option. Explicit image-generation requests remain available while the toggle is off.

## Installation

Extract the complete marketplace ZIP and run its root `Install-Codex.ps1` with PowerShell. The repository marketplace is declared in `.agents/plugins/marketplace.json`. Keep the extracted folder, since it is the local marketplace source. Restart Codex or start a new chat to discover the installed skills.

This plugin requires a desktop client with local execution because its bundled image generator invokes PowerShell and `curl.exe`.

## Privacy and scope

Each user supplies their own image relay address and API key. Generated assets are saved under the active project. The plugin does not use the chat model provider for image generation.

The current generator supports text-to-image only. It cannot upload a source image, mask or reference. The skill checks actual generated files before acceptance and allows at most five further generation requests after the initial one. Connection testing reads the model list; it does not prove that a paid generation request will succeed.
