const form = document.querySelector("[data-options-form]");
const organizationField = document.querySelector("[data-organization-field]");
const organizationInput = document.querySelector("[data-github-organization]");
const status = document.querySelector("[data-status]");
const defaults = Object.fromEntries(new FormData(form));

function updateOrganizationField() {
  const allOrganizations = new FormData(form).get("githubScope") === "all";

  organizationField.hidden = allOrganizations;
  organizationInput.required = !allOrganizations;
}

chrome.storage.sync.get(defaults, (settings) => {
  form.elements.redmineBaseUrl.value = settings.redmineBaseUrl;
  form.elements.githubScope.value = settings.githubScope;
  organizationInput.value = settings.githubOrganization;
  updateOrganizationField();
});

form.addEventListener("change", () => {
  status.textContent = "";
  updateOrganizationField();
});

form.addEventListener("submit", (event) => {
  event.preventDefault();

  const settings = Object.fromEntries(new FormData(form));
  settings.githubOrganization = organizationInput.value.trim();

  chrome.storage.sync.set(settings, () => {
    status.textContent = chrome.runtime.lastError
      ? `Could not save: ${chrome.runtime.lastError.message}`
      : "Saved. Reload open GitHub tabs.";
  });
});
