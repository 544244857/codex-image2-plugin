---
name: image2-setup
description: Open the image2 configuration window when the user asks to configure or test their image relay.
---

When the user asks to configure image2, do not ask them to paste an API key into chat. Locate the installed image2 plugin folder and run its `scripts/Configure.ps1` using Windows PowerShell. The window writes `%USERPROFILE%\.codex\image2.env`; it never changes the chat model configuration. If the user only asks for a direct image and a valid image2 configuration already exists, continue with the image2 skill instead of opening setup.
