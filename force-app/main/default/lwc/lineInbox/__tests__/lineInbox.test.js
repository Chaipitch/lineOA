import { createElement } from "lwc";
import LineInbox from "c/lineInbox";
import getInbox from "@salesforce/apex/LineChatController.getInbox";
import linkToContact from "@salesforce/apex/LineChatController.linkToContact";
import unlinkConversation from "@salesforce/apex/LineChatController.unlinkConversation";
import getConversation from "@salesforce/apex/LineChatController.getConversation";
import getMessages from "@salesforce/apex/LineChatController.getMessages";
import getPollIntervalSeconds from "@salesforce/apex/LineChatController.getPollIntervalSeconds";

jest.mock(
  "@salesforce/apex/LineChatController.getInbox",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.linkToContact",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.unlinkConversation",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getConversation",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getConversations",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getMessages",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getMessagesSince",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.markRead",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.sendText",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getPollIntervalSeconds",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const UNLINKED = {
  id: "a00000000000001",
  name: "Somchai",
  oaName: "OA A",
  unreadCount: 2,
  lastMessageAt: "2026-10-13T03:00:00.000Z",
  lastMessagePreview: "hello",
  canSend: true
};
const LINKED = {
  id: "a00000000000002",
  name: "Niran",
  oaName: "OA A",
  unreadCount: 0,
  lastMessageAt: "2026-10-13T02:00:00.000Z",
  lastMessagePreview: "thanks",
  contactId: "003000000000002",
  contactName: "Niran K.",
  canSend: true
};

async function flush() {
  await Promise.resolve().then().then().then().then().then().then();
}

function setVisibility(state) {
  Object.defineProperty(document, "visibilityState", {
    value: state,
    configurable: true
  });
}

function createComponent() {
  const element = createElement("c-line-inbox", { is: LineInbox });
  document.body.appendChild(element);
  return element;
}

function rows(element) {
  return [...element.shadowRoot.querySelectorAll("button.line-inbox-item")];
}

function buttonByLabel(element, label) {
  return [...element.shadowRoot.querySelectorAll("lightning-button")].find(
    (b) => b.label === label
  );
}

describe("c-line-inbox", () => {
  beforeEach(() => {
    jest.useFakeTimers();
    setVisibility("visible");
    getInbox.mockResolvedValue({
      conversations: [UNLINKED, LINKED],
      hasMore: false,
      isAdmin: false
    });
    getConversation.mockResolvedValue(UNLINKED);
    getMessages.mockResolvedValue({ messages: [], hasMore: false });
    getPollIntervalSeconds.mockResolvedValue(2);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  it("lists unread conversations first, with their Contact or 'not linked'", async () => {
    const element = createComponent();
    await flush();

    expect(getInbox).toHaveBeenCalledWith({
      filter: "unread",
      beforeLastMessageAt: null,
      beforeId: null
    });
    const list = rows(element);
    expect(list.length).toBe(2);
    expect(list[0].textContent).toContain("Somchai");
    expect(list[0].textContent).toContain("c.LINE_Inbox_Unlinked");
    expect(list[1].textContent).toContain("Niran K.");
    expect(element.shadowRoot.querySelector("c-line-chat")).toBeNull();
  });

  it("shows the empty state", async () => {
    getInbox.mockResolvedValue({
      conversations: [],
      hasMore: false,
      isAdmin: false
    });
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-id="empty"]')
    ).not.toBeNull();
  });

  it("reloads when the filter changes", async () => {
    const element = createComponent();
    await flush();

    element.shadowRoot
      .querySelector("lightning-radio-group")
      .dispatchEvent(
        new CustomEvent("change", { detail: { value: "unlinked" } })
      );
    await flush();

    expect(getInbox).toHaveBeenLastCalledWith({
      filter: "unlinked",
      beforeLastMessageAt: null,
      beforeId: null
    });
  });

  it("opens the selected conversation in the chat panel", async () => {
    const element = createComponent();
    await flush();

    rows(element)[0].click();
    await flush();

    const chat = element.shadowRoot.querySelector("c-line-chat");
    expect(chat).not.toBeNull();
    expect(chat.conversationId).toBe(UNLINKED.id);
  });

  it("links the open conversation to the chosen Contact", async () => {
    linkToContact.mockResolvedValue({
      conversation: {
        ...UNLINKED,
        contactId: "003000000000009",
        contactName: "Somchai S."
      },
      placeholderDeleted: true,
      placeholderKept: false
    });
    const element = createComponent();
    await flush();
    rows(element)[0].click();
    await flush();

    expect(buttonByLabel(element, "c.LINE_Inbox_Link").disabled).toBe(true);
    element.shadowRoot
      .querySelector("lightning-record-picker")
      .dispatchEvent(
        new CustomEvent("change", { detail: { recordId: "003000000000009" } })
      );
    await flush();
    buttonByLabel(element, "c.LINE_Inbox_Link").click();
    await flush();

    expect(linkToContact).toHaveBeenCalledWith({
      conversationId: UNLINKED.id,
      contactId: "003000000000009"
    });
    expect(rows(element)[0].textContent).toContain("Somchai S.");
  });

  it("shows unlink only to admins", async () => {
    const element = createComponent();
    await flush();
    rows(element)[1].click();
    await flush();
    expect(buttonByLabel(element, "c.LINE_Inbox_Unlink")).toBeUndefined();

    getInbox.mockResolvedValue({
      conversations: [UNLINKED, LINKED],
      hasMore: false,
      isAdmin: true
    });
    unlinkConversation.mockResolvedValue({
      ...LINKED,
      contactId: null,
      contactName: null
    });
    const adminView = createComponent();
    await flush();
    rows(adminView)[1].click();
    await flush();
    buttonByLabel(adminView, "c.LINE_Inbox_Unlink").click();
    await flush();

    expect(unlinkConversation).toHaveBeenCalledWith({
      conversationId: LINKED.id
    });
  });

  it("refreshes every 30 seconds only while visible", async () => {
    createComponent();
    await flush();
    expect(getInbox).toHaveBeenCalledTimes(1);

    jest.advanceTimersByTime(30000);
    await flush();
    expect(getInbox).toHaveBeenCalledTimes(2);

    setVisibility("hidden");
    document.dispatchEvent(new CustomEvent("visibilitychange"));
    jest.advanceTimersByTime(60000);
    await flush();
    expect(getInbox).toHaveBeenCalledTimes(2);
  });

  it("stops refreshing when removed", async () => {
    const element = createComponent();
    await flush();
    document.body.removeChild(element);
    jest.advanceTimersByTime(60000);
    await flush();
    expect(getInbox).toHaveBeenCalledTimes(1);
  });

  it("shows an error when the inbox can't be read", async () => {
    getInbox.mockRejectedValue({ body: { message: "No access" } });
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector('[role="alert"]').textContent
    ).toContain("No access");
  });
});
