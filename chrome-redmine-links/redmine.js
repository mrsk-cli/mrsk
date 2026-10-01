function issueReference(url) {
  const issueNumber = new URL(url).pathname.match(/^\/issues\/(\d+)\/?$/)?.[1];

  return issueNumber ? `DEV-${issueNumber}` : null;
}

async function copyReference(button, reference, clipboard = navigator.clipboard) {
  try {
    await clipboard.writeText(reference);
    button.textContent = "Copied";
  } catch {
    button.textContent = "Copy failed";
  }
}

function replaceIssueNumber(heading, reference) {
  const marker = `#${reference.slice(4)}`;
  const walker = document.createTreeWalker(heading, NodeFilter.SHOW_TEXT);

  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const index = node.nodeValue.indexOf(marker);
    if (index === -1) continue;

    const button = document.createElement("button");
    button.type = "button";
    button.textContent = reference;
    button.title = `Copy ${reference}`;
    button.dataset.redmineIssueReference = reference;
    button.addEventListener("click", () => copyReference(button, reference));

    const fragment = document.createDocumentFragment();
    fragment.append(node.nodeValue.slice(0, index), button, node.nodeValue.slice(index + marker.length));
    node.replaceWith(fragment);
    return;
  }
}

if (typeof document !== "undefined") {
  const reference = issueReference(window.location.href);
  const marker = reference && `#${reference.slice(4)}`;
  const heading = marker && Array.from(document.querySelectorAll("h2")).find((element) => element.textContent.includes(marker));

  if (heading) replaceIssueNumber(heading, reference);
}

if (typeof module !== "undefined") {
  module.exports = { copyReference, issueReference };
}
