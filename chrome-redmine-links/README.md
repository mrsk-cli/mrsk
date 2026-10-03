# Redmine Links

[Back to mrsk](../README.md)

Chrome extension that turns `DEV-2491` and `#2491` references on GitHub pull requests into Redmine links.

On `redmine.example.com` issue pages, it replaces the heading's `#2491` with a `DEV-2491` button. Clicking the button copies the reference and changes its label to `Copied`.

## Load

```sh
make chrome-extension-build
```

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked from `dist/chrome-redmine-links`.

## Configure

Open the extension's details in `chrome://extensions`, then select **Extension options**.

You can change the Redmine issues base URL and choose between all GitHub organizations or one organization. Enter your GitHub organization in Extension options before links are enabled. No organization is preselected. Reload open GitHub tabs after saving.

The default Redmine URL is an example. Set your own issues base URL in
Extension options for GitHub links. The copy button on Redmine pages uses the
separate host match in `manifest.json`: replace `redmine.example.com` there
with your Redmine host, then reload the unpacked extension. Changing options
does not change the manifest host match.
