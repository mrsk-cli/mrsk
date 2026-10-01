const assert = require("node:assert/strict");
const manifest = require("./manifest.json");
const { DEFAULT_SETTINGS, issueHref, shouldLinkOnPage } = require("./content");
const { copyReference, issueReference } = require("./redmine");

assert.equal(issueHref("DEV-2491"), "https://redmine.matecube-internal.ddns.net/issues/2491");
assert.equal(issueHref("#2491"), "https://redmine.matecube-internal.ddns.net/issues/2491");
assert.equal(issueHref("DEV-2491", "https://redmine.example.com/issues"), "https://redmine.example.com/issues/2491");
assert.equal(issueHref("#76"), null);
assert.equal(shouldLinkOnPage("https://github.com/matecube/orient_sales_portal/pull/265", DEFAULT_SETTINGS), true);
assert.equal(shouldLinkOnPage("https://github.com/other/project/pull/1", DEFAULT_SETTINGS), false);
assert.equal(shouldLinkOnPage("https://github.com/other/project/pull/1", { ...DEFAULT_SETTINGS, githubScope: "all" }), true);
assert.deepEqual(manifest.content_scripts[0].matches, ["https://github.com/*/*/pull/*"]);
assert.equal(manifest.options_page, "options.html");
assert.ok(manifest.permissions.includes("storage"));
assert.equal(issueReference("https://redmine.matecube.dev/issues/2625"), "DEV-2625");
assert.equal(issueReference("https://redmine.matecube.dev/projects/orient"), null);
assert.deepEqual(manifest.content_scripts[1].matches, ["https://redmine.matecube.dev/issues/*"]);

async function testCopyReference() {
  const button = { textContent: "DEV-2625" };
  let copiedText;

  await copyReference(button, "DEV-2625", {
    writeText(text) {
      copiedText = text;
      return Promise.resolve();
    },
  });

  assert.equal(copiedText, "DEV-2625");
  assert.equal(button.textContent, "Copied");
}

testCopyReference().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
