import { createElement } from "lwc";
import LineInvite from "c/lineInvite";
import createInvite from "@salesforce/apex/LineChatController.createInvite";
import { loadScript } from "lightning/platformResourceLoader";

jest.mock(
  "@salesforce/apex/LineChatController.createInvite",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const INVITE = {
  url: "https://line.me/R/oaMessage/%40803ctlbv/?Link%20my%20account%20%23K7PM2QXA",
  code: "K7PM2QXA",
  expiresAt: "2026-10-20T03:00:00.000Z",
  oaName: "TS Chaipitch"
};

async function flush() {
  await Promise.resolve().then().then().then().then().then().then();
}

function createComponent() {
  const element = createElement("c-line-invite", { is: LineInvite });
  element.contactId = "003000000000001";
  document.body.appendChild(element);
  return element;
}

describe("c-line-invite", () => {
  let fillRect;

  beforeEach(() => {
    createInvite.mockResolvedValue(INVITE);
    fillRect = jest.fn();
    HTMLCanvasElement.prototype.getContext = jest.fn(() => ({
      fillRect,
      fillStyle: ""
    }));
    window.qrcode = jest.fn(() => ({
      addData: jest.fn(),
      make: jest.fn(),
      getModuleCount: () => 21,
      isDark: (row, col) => (row + col) % 2 === 0
    }));
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    delete window.qrcode;
  });

  it("creates an invite for the Contact and draws its link as a QR code", async () => {
    const element = createComponent();
    await flush();

    expect(createInvite).toHaveBeenCalledWith({ contactId: "003000000000001" });
    expect(loadScript).toHaveBeenCalled();
    const qr = window.qrcode.mock.results[0].value;
    expect(qr.addData).toHaveBeenCalledWith(INVITE.url);
    expect(fillRect).toHaveBeenCalled();
    expect(
      element.shadowRoot.querySelector('[data-id="invite-url"]').value
    ).toBe(INVITE.url);
    expect(element.shadowRoot.textContent).toContain(
      "c.LINE_Invite_Through_OA"
    );
  });

  it("issues a new code on request", async () => {
    const element = createComponent();
    await flush();

    [...element.shadowRoot.querySelectorAll("lightning-button")]
      .find((b) => b.label === "c.LINE_Invite_New_Code")
      .click();
    await flush();

    expect(createInvite).toHaveBeenCalledTimes(2);
  });

  it("copies the link", async () => {
    const writeText = jest.fn().mockResolvedValue();
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true
    });
    const element = createComponent();
    await flush();

    [...element.shadowRoot.querySelectorAll("lightning-button")]
      .find((b) => b.label === "c.LINE_Invite_Copy")
      .click();
    await flush();

    expect(writeText).toHaveBeenCalledWith(INVITE.url);
    expect(
      [...element.shadowRoot.querySelectorAll("lightning-button")].some(
        (b) => b.label === "c.LINE_Invite_Copied"
      )
    ).toBe(true);
  });

  it("shows the reason when no invite can be made", async () => {
    createInvite.mockRejectedValue({
      body: { message: "c.LINE_Invite_No_OA" }
    });
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe(
      "c.LINE_Invite_No_OA"
    );
    expect(element.shadowRoot.querySelector("canvas")).toBeNull();
  });
});
