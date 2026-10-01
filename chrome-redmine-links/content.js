const DEFAULT_SETTINGS = {
  redmineBaseUrl: "https://redmine.example.com/issues/",
  githubScope: "organization",
  githubOrganization: "",
};
const ISSUE_RE = /\bDEV-(\d+)\b|#(\d{4,})\b/g;
const SKIPPED_TAGS = new Set(["A", "SCRIPT", "STYLE", "TEXTAREA", "INPUT"]);

function issueHref(text, redmineBaseUrl = DEFAULT_SETTINGS.redmineBaseUrl) {
  const match = text.match(/^DEV-(\d+)$|^#(\d{4,})$/);

  return match ? `${redmineBaseUrl.replace(/\/+$/, "")}/${match[1] || match[2]}` : null;
}

function shouldLinkOnPage(url, settings) {
  const page = new URL(url);

  if (page.hostname !== "github.com") return false;
  if (settings.githubScope === "all") return true;

  const organization = settings.githubOrganization.trim().toLowerCase();
  return organization !== "" && page.pathname.split("/")[1].toLowerCase() === organization;
}

function shouldSkip(node) {
  for (let element = node.parentElement; element; element = element.parentElement) {
    if (SKIPPED_TAGS.has(element.tagName) || element.isContentEditable) return true;
  }

  return false;
}

function linkifyTextNode(node, redmineBaseUrl) {
  ISSUE_RE.lastIndex = 0;
  if (!ISSUE_RE.test(node.nodeValue) || shouldSkip(node)) return;

  const fragment = document.createDocumentFragment();
  let index = 0;

  ISSUE_RE.lastIndex = 0;
  node.nodeValue.replace(ISSUE_RE, (text, _devId, _hashId, offset) => {
    fragment.append(node.nodeValue.slice(index, offset));

    const link = document.createElement("a");
    link.href = issueHref(text, redmineBaseUrl);
    link.textContent = text;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    fragment.append(link);

    index = offset + text.length;
  });

  fragment.append(node.nodeValue.slice(index));
  node.replaceWith(fragment);
}

function linkify(root, redmineBaseUrl) {
  if (!root) return;
  if (root.nodeType === Node.TEXT_NODE) return linkifyTextNode(root, redmineBaseUrl);
  if (root.nodeType !== Node.ELEMENT_NODE) return;

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];

  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    nodes.push(node);
  }

  nodes.forEach((node) => linkifyTextNode(node, redmineBaseUrl));
}

if (typeof document !== "undefined") {
  chrome.storage.sync.get(DEFAULT_SETTINGS, (settings) => {
    if (!shouldLinkOnPage(window.location.href, settings)) return;

    linkify(document.body, settings.redmineBaseUrl);

    new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === "characterData") linkifyTextNode(mutation.target, settings.redmineBaseUrl);
        mutation.addedNodes.forEach((node) => linkify(node, settings.redmineBaseUrl));
      }
    }).observe(document.body, { childList: true, subtree: true, characterData: true });
  });
}

if (typeof module !== "undefined") {
  module.exports = { DEFAULT_SETTINGS, issueHref, shouldLinkOnPage };
}
