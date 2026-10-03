# Orient Redmine Links

[Back to mrsk](../README.md)

Chrome extension that turns `DEV-2491` and `#2491` references on GitHub pull requests into Redmine links.

On `redmine.matecube.dev` issue pages, it replaces the heading's `#2491` with a `DEV-2491` button. Clicking the button copies the reference and changes its label to `Copied`.

## Load

```sh
make chrome-extension-build
```

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked from `dist/chrome-redmine-links`.

## Configure

Open the extension's details in `chrome://extensions`, then select **Extension options**.

You can change the Redmine issues base URL and choose between all GitHub organizations or one organization. The default organization is `matecube`. Reload open GitHub tabs after saving.
