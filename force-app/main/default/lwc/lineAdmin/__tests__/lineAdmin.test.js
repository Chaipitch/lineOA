import { createElement } from "lwc";
import LineAdmin from "c/lineAdmin";
import getSettings from "@salesforce/apex/LineAdminController.getSettings";
import saveSettings from "@salesforce/apex/LineAdminController.saveSettings";
import getOAs from "@salesforce/apex/LineAdminController.getOAs";
import registerOA from "@salesforce/apex/LineAdminController.registerOA";

jest.mock(
  "@salesforce/apex/LineAdminController.getSettings",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.saveSettings",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.getOAs",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.registerOA",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const SETTINGS = {
  siteBaseUrl: "https://acme.my.salesforce-sites.com/linewebhook",
  webhookUrl:
    "https://acme.my.salesforce-sites.com/linewebhook/services/apexrest/tsthlineoa/line/webhook",
  fallbackOwnerId: "005000000000001",
  pollIntervalSeconds: 5,
  inviteCodeExpiryDays: 7,
  publicLinkExpiryDays: 7,
  messageRetentionMonths: 0,
  dailySyncEnabled: true,
  updateContactOwnerOnReassign: false
};

const OA = {
  id: "a01000000000001",
  name: "OA A",
  channelId: "1000000001",
  basicId: "@111aaaaa",
  botUserId: "Ubot_a",
  assignedRepId: "005000000000002",
  assignedRepName: "Rep A",
  isActive: true,
  webhookStatus: "OK (200 OK)"
};

async function flush() {
  await Promise.resolve().then().then().then().then().then();
}

function createComponent() {
  const element = createElement("c-line-admin", { is: LineAdmin });
  document.body.appendChild(element);
  return element;
}

function inputByLabel(element, label) {
  return [...element.shadowRoot.querySelectorAll("lightning-input")].find(
    (i) => i.label === label
  );
}

function buttonByLabel(element, label) {
  return [...element.shadowRoot.querySelectorAll("lightning-button")].find(
    (b) => b.label === label
  );
}

describe("c-line-admin", () => {
  beforeEach(() => {
    getSettings.mockResolvedValue({ ...SETTINGS });
    saveSettings.mockResolvedValue({ ...SETTINGS });
    getOAs.mockResolvedValue([OA]);
    registerOA.mockResolvedValue(OA);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows settings, the webhook URL and the registered OAs", async () => {
    const element = createComponent();
    await flush();

    expect(inputByLabel(element, "c.LINE_Admin_Site_Base_Url").value).toBe(
      SETTINGS.siteBaseUrl
    );
    expect(inputByLabel(element, "c.LINE_Admin_Webhook_Url").value).toContain(
      "/services/apexrest/tsthlineoa/line/webhook"
    );
    const table = element.shadowRoot.querySelector("table");
    expect(table.textContent).toContain("OA A");
    expect(table.textContent).toContain("1000000001");
  });

  it("shows an empty state when no OA is registered", async () => {
    getOAs.mockResolvedValue([]);
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.querySelector("table")).toBeNull();
    expect(element.shadowRoot.textContent).toContain("c.LINE_Admin_No_OAs");
  });

  it("saves edited settings", async () => {
    const element = createComponent();
    await flush();

    const input = inputByLabel(element, "c.LINE_Admin_Site_Base_Url");
    input.value = "https://new.my.salesforce-sites.com/linewebhook";
    input.dispatchEvent(new CustomEvent("change"));
    buttonByLabel(element, "c.LINE_Admin_Save").dispatchEvent(
      new CustomEvent("click")
    );
    await flush();

    expect(saveSettings).toHaveBeenCalled();
    expect(saveSettings.mock.calls[0][0].siteBaseUrl).toBe(
      "https://new.my.salesforce-sites.com/linewebhook"
    );
  });

  it("keeps the register button disabled until every field is filled", async () => {
    const element = createComponent();
    await flush();

    const registerButton = buttonByLabel(element, "c.LINE_Admin_Register");
    expect(registerButton.disabled).toBe(true);

    const channelId = inputByLabel(element, "c.LINE_Admin_Channel_Id");
    channelId.value = "1000000001";
    channelId.dispatchEvent(new CustomEvent("change"));
    const secret = inputByLabel(element, "c.LINE_Admin_Channel_Secret");
    secret.value = "fake_secret";
    secret.dispatchEvent(new CustomEvent("change"));
    await flush();

    // Still disabled: no rep chosen yet.
    expect(buttonByLabel(element, "c.LINE_Admin_Register").disabled).toBe(true);

    element.shadowRoot
      .querySelectorAll("lightning-record-picker")[1]
      .dispatchEvent(
        new CustomEvent("change", { detail: { recordId: "005000000000002" } })
      );
    await flush();

    expect(buttonByLabel(element, "c.LINE_Admin_Register").disabled).toBe(
      false
    );
  });

  it("registers an OA and clears the secret afterwards", async () => {
    const element = createComponent();
    await flush();

    const channelId = inputByLabel(element, "c.LINE_Admin_Channel_Id");
    channelId.value = "1000000001";
    channelId.dispatchEvent(new CustomEvent("change"));
    const secret = inputByLabel(element, "c.LINE_Admin_Channel_Secret");
    secret.value = "fake_secret";
    secret.dispatchEvent(new CustomEvent("change"));
    element.shadowRoot
      .querySelectorAll("lightning-record-picker")[1]
      .dispatchEvent(
        new CustomEvent("change", { detail: { recordId: "005000000000002" } })
      );
    await flush();

    buttonByLabel(element, "c.LINE_Admin_Register").dispatchEvent(
      new CustomEvent("click")
    );
    await flush();

    expect(registerOA).toHaveBeenCalledWith({
      channelId: "1000000001",
      channelSecret: "fake_secret",
      repId: "005000000000002"
    });
    // The secret must not linger in the form after use.
    expect(inputByLabel(element, "c.LINE_Admin_Channel_Secret").value).toBe("");
    expect(getOAs).toHaveBeenCalledTimes(2);
  });

  it("reports a registration failure to the admin", async () => {
    registerOA.mockRejectedValue({
      body: { message: "LINE OA credentials are invalid." }
    });
    const element = createComponent();
    await flush();
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    const channelId = inputByLabel(element, "c.LINE_Admin_Channel_Id");
    channelId.value = "1000000001";
    channelId.dispatchEvent(new CustomEvent("change"));
    const secret = inputByLabel(element, "c.LINE_Admin_Channel_Secret");
    secret.value = "wrong";
    secret.dispatchEvent(new CustomEvent("change"));
    element.shadowRoot
      .querySelectorAll("lightning-record-picker")[1]
      .dispatchEvent(
        new CustomEvent("change", { detail: { recordId: "005000000000002" } })
      );
    await flush();
    buttonByLabel(element, "c.LINE_Admin_Register").dispatchEvent(
      new CustomEvent("click")
    );
    await flush();

    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.message).toContain(
      "credentials are invalid"
    );
  });

  it("shows an error when the page cannot load", async () => {
    getSettings.mockRejectedValue({
      body: { message: "Only LINE admins can open this page." }
    });
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.textContent).toContain("Only LINE admins");
  });
});
