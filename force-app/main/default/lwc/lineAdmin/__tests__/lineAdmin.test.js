import { createElement } from "lwc";
import LineAdmin from "c/lineAdmin";
import getSettings from "@salesforce/apex/LineAdminController.getSettings";
import saveSettings from "@salesforce/apex/LineAdminController.saveSettings";
import getOAs from "@salesforce/apex/LineAdminController.getOAs";
import registerOA from "@salesforce/apex/LineAdminController.registerOA";
import getJobs from "@salesforce/apex/LineAdminController.getJobs";
import scheduleJobs from "@salesforce/apex/LineAdminController.scheduleJobs";
import unscheduleJobs from "@salesforce/apex/LineAdminController.unscheduleJobs";
import runDailySyncNow from "@salesforce/apex/LineAdminController.runDailySyncNow";
import removeOA from "@salesforce/apex/LineAdminController.removeOA";
import LightningConfirm from "lightning/confirm";

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
jest.mock(
  "@salesforce/apex/LineAdminController.getJobs",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.scheduleJobs",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.unscheduleJobs",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.runDailySyncNow",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineAdminController.removeOA",
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
  webhookStatus: "OK (200 OK)",
  credentialStatus: "Valid"
};

const NOT_SCHEDULED = {
  scheduled: false,
  dailySyncEnabled: true,
  orgTimeZone: "Asia/Bangkok",
  userTimeZone: "Asia/Bangkok",
  timeZonesDiffer: false
};
const SCHEDULED = {
  scheduled: true,
  nextRunAt: "2026-09-30T18:00:00.000Z",
  dailySyncEnabled: true,
  lastRunStatus: "Completed",
  lastRunAt: "2026-09-29T18:05:00.000Z",
  lastRunErrors: 0,
  orgTimeZone: "Asia/Bangkok",
  userTimeZone: "Asia/Bangkok",
  timeZonesDiffer: false
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
    getJobs.mockResolvedValue({ ...NOT_SCHEDULED });
    scheduleJobs.mockResolvedValue({ ...SCHEDULED });
    unscheduleJobs.mockResolvedValue({ ...NOT_SCHEDULED });
    runDailySyncNow.mockResolvedValue({ ...SCHEDULED });
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

  it("warns when the nightly job is not scheduled, and schedules it", async () => {
    const element = createComponent();
    await flush();

    const root = element.shadowRoot;
    expect(root.querySelector('[data-id="job-not-scheduled"]')).not.toBeNull();
    expect(root.querySelector('[data-id="unschedule"]').disabled).toBe(true);

    root
      .querySelector('[data-id="schedule"]')
      .dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(scheduleJobs).toHaveBeenCalled();
    expect(root.querySelector('[data-id="job-scheduled"]')).not.toBeNull();
    expect(
      root.querySelector('[data-id="job-last-run"]').textContent
    ).toContain("Completed");
    expect(root.querySelector('[data-id="unschedule"]').disabled).toBe(false);
  });

  it("unschedules the nightly job", async () => {
    getJobs.mockResolvedValue({ ...SCHEDULED });
    const element = createComponent();
    await flush();

    element.shadowRoot
      .querySelector('[data-id="unschedule"]')
      .dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(unscheduleJobs).toHaveBeenCalled();
    expect(
      element.shadowRoot.querySelector('[data-id="job-not-scheduled"]')
    ).not.toBeNull();
  });

  it("runs the daily sync now and confirms it started", async () => {
    const element = createComponent();
    await flush();
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    element.shadowRoot
      .querySelector('[data-id="run-now"]')
      .dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(runDailySyncNow).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.message).toBe(
      "c.LINE_Admin_Jobs_Started"
    );
  });

  it("says so when daily sync is turned off in settings", async () => {
    getJobs.mockResolvedValue({ scheduled: true, dailySyncEnabled: false });
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.textContent).toContain(
      "c.LINE_Admin_Jobs_Sync_Off"
    );
  });

  it("reports a failed job action", async () => {
    scheduleJobs.mockRejectedValue({
      body: { message: "Only LINE admins can do this." }
    });
    const element = createComponent();
    await flush();
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    element.shadowRoot
      .querySelector('[data-id="schedule"]')
      .dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
  });

  it("shows each OA's credential status", async () => {
    getOAs.mockResolvedValue([
      OA,
      {
        ...OA,
        id: "a01000000000002",
        name: "OA B",
        credentialStatus: "Rejected"
      },
      { ...OA, id: "a01000000000003", name: "OA C", credentialStatus: null }
    ]);
    const element = createComponent();
    await flush();

    const cells = [
      ...element.shadowRoot.querySelectorAll('[data-id="credential"]')
    ];
    expect(cells.map((c) => c.textContent.trim())).toEqual([
      "c.LINE_Admin_Credential_Valid",
      "c.LINE_Admin_Credential_Rejected",
      "c.LINE_Admin_Credential_Unchecked"
    ]);
    expect(cells[1].className).toContain("slds-text-color_error");
  });

  it("removes an OA after the admin confirms", async () => {
    LightningConfirm.open = jest.fn().mockResolvedValue(true);
    removeOA.mockResolvedValue([
      { ...OA, isActive: false, credentialStatus: "Removed" }
    ]);
    const element = createComponent();
    await flush();
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    buttonByLabel(element, "c.LINE_Admin_Remove").dispatchEvent(
      new CustomEvent("click")
    );
    await flush();

    expect(LightningConfirm.open).toHaveBeenCalled();
    expect(removeOA).toHaveBeenCalledWith({ oaConfigId: OA.id });
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("success");
    expect(buttonByLabel(element, "c.LINE_Admin_Remove").disabled).toBe(true);
    expect(
      element.shadowRoot.querySelector('[data-id="credential"]').textContent
    ).toContain("c.LINE_Admin_Credential_Removed");
  });

  it("does nothing when the admin cancels the removal", async () => {
    LightningConfirm.open = jest.fn().mockResolvedValue(false);
    const element = createComponent();
    await flush();

    buttonByLabel(element, "c.LINE_Admin_Remove").dispatchEvent(
      new CustomEvent("click")
    );
    await flush();

    expect(removeOA).not.toHaveBeenCalled();
  });

  it("shows the time zone that defines a day, and warns when the admin's differs", async () => {
    getJobs.mockResolvedValue({
      ...NOT_SCHEDULED,
      orgTimeZone: "America/Los_Angeles",
      userTimeZone: "Asia/Bangkok",
      timeZonesDiffer: true
    });
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-id="org-zone"]').textContent
    ).toContain("America/Los_Angeles");
    expect(
      element.shadowRoot.querySelector('[data-id="zone-mismatch"]').textContent
    ).toContain("Asia/Bangkok");
  });

  it("shows no time zone warning when they match", async () => {
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-id="zone-mismatch"]')
    ).toBeNull();
  });
});
