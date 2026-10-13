import { createElement } from "lwc";
import LineChat from "c/lineChat";
import LightningModal from "lightning/modal";
import { getNavigateCalledWith } from "lightning/navigation";

// The stock stub doesn't record navigation; this one keeps the last page reference.
jest.mock("lightning/navigation", () => {
  const Navigate = Symbol("Navigate");
  const calls = [];
  const NavigationMixin = (Base) =>
    class extends Base {
      [Navigate](pageReference) {
        calls.push(pageReference);
      }
    };
  NavigationMixin.Navigate = Navigate;
  return {
    NavigationMixin,
    getNavigateCalledWith: () => calls[calls.length - 1]
  };
});
import getConversations from "@salesforce/apex/LineChatController.getConversations";
import getConversation from "@salesforce/apex/LineChatController.getConversation";
import getMessages from "@salesforce/apex/LineChatController.getMessages";
import getMessagesSince from "@salesforce/apex/LineChatController.getMessagesSince";
import markRead from "@salesforce/apex/LineChatController.markRead";
import sendText from "@salesforce/apex/LineChatController.sendText";
import prepareFile from "@salesforce/apex/LineChatController.prepareFile";
import sendFile from "@salesforce/apex/LineChatController.sendFile";
import getPollIntervalSeconds from "@salesforce/apex/LineChatController.getPollIntervalSeconds";

jest.mock(
  "@salesforce/apex/LineChatController.getConversations",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getConversation",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.prepareFile",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.sendFile",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LineChatController.getMessages",
  () => ({ default: jest.fn() }),
  {
    virtual: true
  }
);
jest.mock(
  "@salesforce/apex/LineChatController.getMessagesSince",
  () => ({ default: jest.fn() }),
  {
    virtual: true
  }
);
jest.mock(
  "@salesforce/apex/LineChatController.markRead",
  () => ({ default: jest.fn() }),
  {
    virtual: true
  }
);
jest.mock(
  "@salesforce/apex/LineChatController.sendText",
  () => ({ default: jest.fn() }),
  {
    virtual: true
  }
);
jest.mock(
  "@salesforce/apex/LineChatController.getPollIntervalSeconds",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const CONVERSATION = {
  id: "a00000000000001",
  name: "Somchai",
  status: "Following",
  unreadCount: 2,
  oaName: "OA A",
  isPrimaryOa: true,
  canSend: true
};

function inboundMessage(id, text, sentAt = "2026-09-22T03:00:00.000Z") {
  return {
    id,
    text,
    sentAt,
    isOutbound: false,
    direction: "Inbound",
    messageType: "text",
    status: "Received"
  };
}

function setVisibility(state) {
  Object.defineProperty(document, "visibilityState", {
    value: state,
    configurable: true
  });
  document.dispatchEvent(new CustomEvent("visibilitychange"));
}

async function flush() {
  // Let the component's chained promises settle (six microtask ticks).
  await Promise.resolve().then().then().then().then().then().then();
}

function createComponent() {
  const element = createElement("c-line-chat", { is: LineChat });
  element.recordId = "003000000000001";
  document.body.appendChild(element);
  return element;
}

describe("c-line-chat", () => {
  beforeEach(() => {
    jest.useFakeTimers();
    setVisibility("visible");
    getPollIntervalSeconds.mockResolvedValue(5);
    getConversations.mockResolvedValue([CONVERSATION]);
    getMessages.mockResolvedValue({
      messages: [inboundMessage("m1", "สวัสดีครับ")],
      hasMore: false
    });
    getMessagesSince.mockResolvedValue([]);
    markRead.mockResolvedValue(0);
    sendText.mockResolvedValue({
      id: "m2",
      text: "Hello",
      sentAt: "2026-09-22T03:05:00.000Z",
      isOutbound: true,
      direction: "Outbound",
      messageType: "text",
      status: "Sent"
    });
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  it("renders the conversation history and marks it read", async () => {
    const element = createComponent();
    await flush();

    expect(getConversations).toHaveBeenCalledWith({
      contactId: "003000000000001"
    });
    const bubbles = element.shadowRoot.querySelectorAll(".line-bubble");
    expect(bubbles.length).toBe(1);
    expect(bubbles[0].textContent).toContain("สวัสดีครับ");
    expect(markRead).toHaveBeenCalledWith({ conversationId: CONVERSATION.id });
  });

  it("shows the empty state with an invite button when there is no conversation", async () => {
    getConversations.mockResolvedValue([]);
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.querySelectorAll(".line-bubble").length).toBe(0);
    const button = element.shadowRoot.querySelector("lightning-button");
    expect(button).not.toBeNull();
    expect(getMessages).not.toHaveBeenCalled();
  });

  it("renders a placeholder instead of content for non-text messages", async () => {
    getMessages.mockResolvedValue({
      messages: [
        { ...inboundMessage("m1", null), messageType: "image" },
        {
          ...inboundMessage("m2", null),
          messageType: "file",
          fileName: "quote.pdf"
        }
      ],
      hasMore: false
    });
    const element = createComponent();
    await flush();

    const text = element.shadowRoot.querySelector(".line-messages").textContent;
    expect(text).toContain("quote.pdf");
    expect(element.shadowRoot.querySelectorAll(".line-bubble").length).toBe(2);
  });

  it("shows a sticker as its picture from LINE", async () => {
    const url =
      "https://stickershop.line-scdn.net/stickershop/v1/sticker/1988/android/sticker.png";
    getMessages.mockResolvedValue({
      messages: [
        {
          ...inboundMessage("m1", null),
          messageType: "sticker",
          stickerPackageId: "446",
          stickerId: "1988",
          stickerUrl: url
        }
      ],
      hasMore: false
    });
    const element = createComponent();
    await flush();

    const img = element.shadowRoot.querySelector("img.line-sticker");
    expect(img).not.toBeNull();
    expect(img.src).toBe(url);
    expect(img.alt).toBe("c.LINE_Preview_Sticker");
    expect(
      element.shadowRoot.querySelector(".line-bubble_sticker")
    ).not.toBeNull();
  });

  it("falls back to the placeholder when a sticker picture won't load", async () => {
    getMessages.mockResolvedValue({
      messages: [
        {
          ...inboundMessage("m1", null),
          messageType: "sticker",
          stickerId: "1988",
          stickerUrl:
            "https://stickershop.line-scdn.net/stickershop/v1/sticker/1988/android/sticker.png"
        }
      ],
      hasMore: false
    });
    const element = createComponent();
    await flush();

    element.shadowRoot
      .querySelector("img.line-sticker")
      .dispatchEvent(new CustomEvent("error"));
    await flush();

    expect(element.shadowRoot.querySelector("img.line-sticker")).toBeNull();
    expect(
      element.shadowRoot.querySelector(".line-messages").textContent
    ).toContain("c.LINE_Preview_Sticker");
  });

  it("shows the placeholder for a sticker without a usable picture", async () => {
    getMessages.mockResolvedValue({
      messages: [{ ...inboundMessage("m1", null), messageType: "sticker" }],
      hasMore: false
    });
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.querySelector("img.line-sticker")).toBeNull();
    expect(
      element.shadowRoot.querySelector(".line-messages").textContent
    ).toContain("c.LINE_Preview_Sticker");
  });

  it("sends a message and appends it", async () => {
    const element = createComponent();
    await flush();

    // The stub element carries the value; the change event's target is the element itself.
    const textarea = element.shadowRoot.querySelector("lightning-textarea");
    textarea.value = "Hello";
    textarea.dispatchEvent(new CustomEvent("change"));
    await flush();

    const sendButton = [
      ...element.shadowRoot.querySelectorAll("lightning-button")
    ].pop();
    sendButton.dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(sendText).toHaveBeenCalledWith({
      conversationId: CONVERSATION.id,
      text: "Hello"
    });
    expect(element.shadowRoot.querySelectorAll(".line-bubble").length).toBe(2);
  });

  it("is read-only for someone who is not the OA's assigned rep", async () => {
    getConversations.mockResolvedValue([{ ...CONVERSATION, canSend: false }]);
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-id="read-only-notice"]')
    ).not.toBeNull();
    const textarea = element.shadowRoot.querySelector("lightning-textarea");
    textarea.value = "Hello";
    textarea.dispatchEvent(new CustomEvent("change"));
    await flush();
    const sendButton = [
      ...element.shadowRoot.querySelectorAll("lightning-button")
    ].pop();
    expect(sendButton.disabled).toBe(true);
  });

  it("shows no read-only notice to the assigned rep", async () => {
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-id="read-only-notice"]')
    ).toBeNull();
  });

  it("opens one conversation by Id when used from the inbox", async () => {
    getConversation.mockResolvedValue({
      ...CONVERSATION,
      id: "a00000000000009"
    });
    const element = createElement("c-line-chat", { is: LineChat });
    element.conversationId = "a00000000000009";
    const onRead = jest.fn();
    element.addEventListener("read", onRead);
    document.body.appendChild(element);
    await flush();

    expect(getConversation).toHaveBeenCalledWith({
      conversationId: "a00000000000009"
    });
    expect(getConversations).not.toHaveBeenCalled();
    expect(onRead).toHaveBeenCalled();
    expect(onRead.mock.calls[0][0].detail.conversationId).toBe(
      "a00000000000009"
    );
  });

  it("switches conversation when the inbox selects another", async () => {
    getConversation.mockResolvedValue({
      ...CONVERSATION,
      id: "a00000000000009"
    });
    const element = createElement("c-line-chat", { is: LineChat });
    element.conversationId = "a00000000000009";
    document.body.appendChild(element);
    await flush();

    getConversation.mockResolvedValue({
      ...CONVERSATION,
      id: "a00000000000010"
    });
    element.conversationId = "a00000000000010";
    await flush();

    expect(getConversation).toHaveBeenLastCalledWith({
      conversationId: "a00000000000010"
    });
  });

  it("opens the QR invite for this Contact", async () => {
    getConversations.mockResolvedValue([]);
    const element = createComponent();
    await flush();

    [...element.shadowRoot.querySelectorAll("lightning-button")]
      .find((b) => b.label === "c.LINE_Chat_Invite")
      .click();
    await flush();

    expect(LightningModal.open).toHaveBeenCalledWith(
      expect.objectContaining({ contactId: "003000000000001" })
    );
    expect(getConversations).toHaveBeenCalledTimes(2);
  });

  it("shows a saved image as its thumbnail and opens the file preview", async () => {
    getMessages.mockResolvedValue({
      messages: [
        {
          ...inboundMessage("m9", null),
          messageType: "image",
          contentDocumentId: "069000000000001",
          contentVersionId: "068000000000001",
          fileName: "LINE image.jpg"
        }
      ],
      hasMore: false
    });
    const element = createComponent();
    await flush();

    const img = element.shadowRoot.querySelector("img.line-image");
    expect(img.src).toContain("versionId=068000000000001");
    element.shadowRoot.querySelector("button.line-file-button").click();
    expect(getNavigateCalledWith().state.selectedRecordId).toBe(
      "069000000000001"
    );
  });

  it("shows a saved file by name, and the state of one still being saved", async () => {
    getMessages.mockResolvedValue({
      messages: [
        {
          ...inboundMessage("m10", null),
          messageType: "file",
          fileName: "quote.pdf",
          contentDocumentId: "069000000000002"
        },
        {
          ...inboundMessage("m11", null),
          messageType: "file",
          fileName: "huge.zip",
          status: "Too Large"
        }
      ],
      hasMore: false
    });
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector("button.line-file-button").textContent
    ).toContain("quote.pdf");
    expect(
      element.shadowRoot.querySelector('[data-id="file-status"]').textContent
    ).toContain("c.LINE_File_Too_Large");
  });

  it("updates a file still being saved when polling", async () => {
    const downloading = {
      ...inboundMessage("m12", null),
      messageType: "image",
      status: "Downloading"
    };
    getMessages.mockResolvedValueOnce({
      messages: [downloading],
      hasMore: false
    });
    getMessages.mockResolvedValue({
      messages: [
        {
          ...downloading,
          status: "Received",
          contentDocumentId: "069000000000003",
          contentVersionId: "068000000000003"
        }
      ],
      hasMore: false
    });
    const element = createComponent();
    await flush();
    expect(
      element.shadowRoot.querySelector('[data-id="file-status"]')
    ).not.toBeNull();

    jest.advanceTimersByTime(5000);
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-id="file-status"]')
    ).toBeNull();
    expect(element.shadowRoot.querySelector("img.line-image")).not.toBeNull();
  });

  it("sends an uploaded file: link first, then the push", async () => {
    prepareFile.mockResolvedValue();
    sendFile.mockResolvedValue({
      ...inboundMessage("m20", null),
      isOutbound: true,
      direction: "Outbound",
      messageType: "file",
      fileName: "quote.pdf",
      contentDocumentId: "069000000000020",
      status: "Sent"
    });
    const element = createComponent();
    await flush();

    element.shadowRoot.querySelector("lightning-file-upload").dispatchEvent(
      new CustomEvent("uploadfinished", {
        detail: {
          files: [{ documentId: "069000000000020", name: "quote.pdf" }]
        }
      })
    );
    await flush();

    const ids = {
      conversationId: CONVERSATION.id,
      contentDocumentId: "069000000000020"
    };
    expect(prepareFile).toHaveBeenCalledWith(ids);
    expect(sendFile).toHaveBeenCalledWith(ids);
    expect(prepareFile.mock.invocationCallOrder[0]).toBeLessThan(
      sendFile.mock.invocationCallOrder[0]
    );
    expect(element.shadowRoot.textContent).toContain("quote.pdf");
  });

  it("does not offer uploads to someone who can only read", async () => {
    getConversations.mockResolvedValue([{ ...CONVERSATION, canSend: false }]);
    const element = createComponent();
    await flush();

    expect(
      element.shadowRoot.querySelector("lightning-file-upload").disabled
    ).toBe(true);
  });

  it("shows an error toast when sending fails", async () => {
    sendText.mockRejectedValue({
      body: { message: "This LINE OA has used its monthly message allowance." }
    });
    const element = createComponent();
    await flush();
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    const textarea = element.shadowRoot.querySelector("lightning-textarea");
    textarea.value = "Hello";
    textarea.dispatchEvent(new CustomEvent("change"));
    await flush();
    [...element.shadowRoot.querySelectorAll("lightning-button")]
      .pop()
      .dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.message).toContain(
      "monthly message allowance"
    );
    expect(element.shadowRoot.querySelectorAll(".line-bubble").length).toBe(1);
  });

  it("polls only while the tab is visible", async () => {
    createComponent();
    await flush();
    expect(getMessagesSince).not.toHaveBeenCalled();

    jest.advanceTimersByTime(5000);
    await flush();
    expect(getMessagesSince).toHaveBeenCalledTimes(1);

    setVisibility("hidden");
    await flush();
    jest.advanceTimersByTime(20000);
    await flush();
    expect(getMessagesSince).toHaveBeenCalledTimes(1);

    setVisibility("visible");
    await flush();
    expect(getMessagesSince).toHaveBeenCalledTimes(2);
  });

  it("appends polled messages and skips ones it already has", async () => {
    const element = createComponent();
    await flush();
    getMessagesSince.mockResolvedValue([
      inboundMessage("m1", "สวัสดีครับ"),
      inboundMessage("m9", "new one", "2026-09-22T03:10:00.000Z")
    ]);

    jest.advanceTimersByTime(5000);
    await flush();

    expect(element.shadowRoot.querySelectorAll(".line-bubble").length).toBe(2);
    expect(
      element.shadowRoot.querySelector(".line-messages").textContent
    ).toContain("new one");
    expect(markRead).toHaveBeenCalledTimes(2);
  });

  it("stops polling when the component is removed", async () => {
    const element = createComponent();
    await flush();
    document.body.removeChild(element);

    jest.advanceTimersByTime(30000);
    await flush();

    expect(getMessagesSince).not.toHaveBeenCalled();
  });

  it("loads older messages on demand", async () => {
    getMessages.mockResolvedValueOnce({
      messages: [inboundMessage("m5", "newest page")],
      hasMore: true
    });
    const element = createComponent();
    await flush();

    getMessages.mockResolvedValueOnce({
      messages: [
        inboundMessage("m4", "older page", "2026-09-22T02:00:00.000Z")
      ],
      hasMore: false
    });
    element.shadowRoot
      .querySelector("lightning-button")
      .dispatchEvent(new CustomEvent("click"));
    await flush();

    const bubbles = element.shadowRoot.querySelectorAll(".line-bubble");
    expect(bubbles.length).toBe(2);
    expect(bubbles[0].textContent).toContain("older page");
    expect(getMessages).toHaveBeenLastCalledWith({
      conversationId: CONVERSATION.id,
      beforeSentAt: "2026-09-22T03:00:00.000Z",
      beforeId: "m5",
      pageSize: null
    });
  });

  it("loads older messages when the list is scrolled to the top", async () => {
    getMessages.mockResolvedValueOnce({
      messages: [inboundMessage("m5", "newest page")],
      hasMore: true
    });
    const element = createComponent();
    await flush();

    getMessages.mockResolvedValueOnce({
      messages: [
        inboundMessage("m4", "older page", "2026-09-22T02:00:00.000Z")
      ],
      hasMore: false
    });
    const list = element.shadowRoot.querySelector(".line-messages");
    list.scrollTop = 0;
    list.dispatchEvent(new CustomEvent("scroll"));
    await flush();

    expect(getMessages).toHaveBeenCalledTimes(2);
    expect(element.shadowRoot.querySelectorAll(".line-bubble").length).toBe(2);
  });

  it("does not load older messages while scrolled away from the top", async () => {
    getMessages.mockResolvedValueOnce({
      messages: [inboundMessage("m5", "newest page")],
      hasMore: true
    });
    const element = createComponent();
    await flush();

    const list = element.shadowRoot.querySelector(".line-messages");
    list.scrollTop = 500;
    list.dispatchEvent(new CustomEvent("scroll"));
    await flush();

    expect(getMessages).toHaveBeenCalledTimes(1);
  });

  it("does not ask for older messages when there are none", async () => {
    const element = createComponent();
    await flush();

    const list = element.shadowRoot.querySelector(".line-messages");
    list.scrollTop = 0;
    list.dispatchEvent(new CustomEvent("scroll"));
    await flush();

    expect(getMessages).toHaveBeenCalledTimes(1);
  });

  it("shows an error when the conversation cannot be read", async () => {
    getConversations.mockRejectedValue({ body: { message: "No access" } });
    const element = createComponent();
    await flush();

    expect(element.shadowRoot.textContent).toContain("No access");
  });
});
