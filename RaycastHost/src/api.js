// @raycast/api réimplémentée pour Prism. Les composants rendent des éléments « hôtes » (chaînes) que le
// réconciliateur sérialise ; les fonctions qui touchent au Mac passent par Prism (`bridge.request`) ou par Node.
const React = require("react");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");
const { EventEmitter } = require("events");
const IconValues = require("./icons");

const h = React.createElement;
const bridge = {
  request: () => Promise.reject(new Error("hôte non initialisé")),
  session: { preferences: {}, environment: {} },
};

// ——— Énumérations ———

const Icon = Object.freeze({ ...IconValues });

const Color = Object.freeze({
  Blue: "raycast-blue",
  Green: "raycast-green",
  Magenta: "raycast-magenta",
  Orange: "raycast-orange",
  Purple: "raycast-purple",
  Red: "raycast-red",
  Yellow: "raycast-yellow",
  PrimaryText: "raycast-primary-text",
  SecondaryText: "raycast-secondary-text",
});

const Image = { Mask: Object.freeze({ Circle: "circle", RoundedRectangle: "roundedRectangle" }) };

const LaunchType = Object.freeze({ UserInitiated: "userInitiated", Background: "background" });
const PopToRootType = Object.freeze({ Default: "default", Immediate: "immediate", Suspended: "suspended" });

const shortcut = (modifiers, key) => ({ modifiers, key });
const Keyboard = {
  Shortcut: {
    Common: Object.freeze({
      Copy: shortcut(["cmd", "shift"], "c"),
      CopyDeeplink: shortcut(["cmd", "shift"], "c"),
      CopyName: shortcut(["cmd", "shift"], "."),
      CopyPath: shortcut(["cmd", "shift"], ","),
      Duplicate: shortcut(["cmd"], "d"),
      Edit: shortcut(["cmd"], "e"),
      MoveDown: shortcut(["cmd", "shift"], "arrowDown"),
      MoveUp: shortcut(["cmd", "shift"], "arrowUp"),
      New: shortcut(["cmd"], "n"),
      Open: shortcut(["cmd"], "o"),
      OpenWith: shortcut(["cmd", "shift"], "o"),
      Pin: shortcut(["cmd", "shift"], "p"),
      Refresh: shortcut(["cmd"], "r"),
      Remove: shortcut(["ctrl"], "x"),
      RemoveAll: shortcut(["ctrl", "shift"], "x"),
      ToggleQuickLook: shortcut(["cmd"], "y"),
    }),
  },
};

// ——— Navigation ———

const NavigationContext = React.createContext({
  push: () => {},
  pop: () => {},
});

function useNavigation() {
  return React.useContext(NavigationContext);
}

// ——— Emplacements : un élément passé en prop (actions, détail, menu) devient un enfant nommé ———

function slot(name, element) {
  return element == null || element === false ? null : h("slot", { name }, element);
}

function hostComponent(type, slots = []) {
  const component = (props) => {
    const rest = { ...props };
    const children = [];
    for (const name of slots) {
      children.push(slot(name, rest[name]));
      delete rest[name];
    }
    const own = rest.children;
    delete rest.children;
    return h(type, rest, own, ...children);
  };
  component.displayName = type;
  return component;
}

// ——— Métadonnées (détail d'un élément, Detail) ———

const Metadata = hostComponent("metadata");
Metadata.Label = hostComponent("metadata-label");
Metadata.Link = hostComponent("metadata-link");
Metadata.Separator = hostComponent("metadata-separator");
Metadata.TagList = hostComponent("metadata-taglist");
Metadata.TagList.Item = hostComponent("metadata-tag");

// ——— Listes ———

const Dropdown = hostComponent("dropdown");
Dropdown.Item = hostComponent("dropdown-item");
Dropdown.Section = hostComponent("dropdown-section");

const List = hostComponent("list", ["actions", "searchBarAccessory"]);
List.Section = hostComponent("list-section");
List.Item = hostComponent("list-item", ["actions", "detail"]);
List.Item.Detail = hostComponent("item-detail", ["metadata"]);
List.Item.Detail.Metadata = Metadata;
List.EmptyView = hostComponent("list-empty", ["actions"]);
List.Dropdown = Dropdown;

const Grid = hostComponent("grid", ["actions", "searchBarAccessory"]);
Grid.Section = hostComponent("grid-section");
Grid.Item = hostComponent("grid-item", ["actions"]);
Grid.EmptyView = hostComponent("grid-empty", ["actions"]);
Grid.Dropdown = Dropdown;
Grid.Fit = Object.freeze({ Contain: "contain", Fill: "fill" });
Grid.Inset = Object.freeze({ Zero: "zero", Small: "small", Medium: "medium", Large: "large" });
Grid.ItemSize = Object.freeze({ Small: "small", Medium: "medium", Large: "large" });

const Detail = hostComponent("detail", ["actions", "metadata"]);
Detail.Metadata = Metadata;

// ——— Menu de la barre des menus (affiché comme une liste dans Prism) ———

const MenuBarExtra = hostComponent("menubar");
MenuBarExtra.Item = hostComponent("menubar-item", ["alternate"]);
MenuBarExtra.Section = hostComponent("menubar-section");
MenuBarExtra.Submenu = hostComponent("menubar-submenu");

// ——— Formulaires ———

const FormContext = React.createContext(null);
const forms = new Map();
let nextFormKey = 1;

function storedFormValues(key) {
  return readJSON(path.join(supportDirectory(), ".form-values.json"))[key] || {};
}

function storeFormValue(key, id, value) {
  const file = path.join(supportDirectory(), ".form-values.json");
  const all = readJSON(file);
  all[key] = { ...(all[key] || {}), [id]: value };
  writeJSON(file, all);
}

function emptyValue(kind) {
  switch (kind) {
    case "checkbox":
      return false;
    case "tagpicker":
    case "filepicker":
      return [];
    case "datepicker":
      return null;
    default:
      return "";
  }
}

/** Le formulaire tient les valeurs de ses champs : `Action.SubmitForm` les reçoit, Prism les modifie. */
function Form(props) {
  const registry = React.useRef(null);
  if (!registry.current) {
    registry.current = { key: nextFormKey++, values: {}, kinds: {}, fields: {}, defaults: {} };
    forms.set(registry.current.key, registry.current);
  }
  React.useEffect(() => {
    const key = registry.current.key;
    return () => forms.delete(key);
  }, []);
  const rest = { ...props, formKey: registry.current.key };
  const actions = rest.actions;
  const accessory = rest.searchBarAccessory;
  delete rest.actions;
  delete rest.searchBarAccessory;
  const children = rest.children;
  delete rest.children;
  return h(FormContext.Provider, { value: registry.current }, h("form", rest, children, slot("actions", actions), slot("searchBarAccessory", accessory)));
}

function formField(kind) {
  const component = React.forwardRef((props, ref) => {
    const registry = React.useContext(FormContext);
    const id = props.id;
    if (registry && id) {
      registry.kinds[id] = kind;
      registry.fields[id] = props;
      if (!(id in registry.values)) {
        const stored = props.storeValue ? storedFormValues(commandKey())[id] : undefined;
        const initial = props.value !== undefined ? props.value : stored !== undefined ? revive(kind, stored) : props.defaultValue;
        registry.values[id] = initial !== undefined ? initial : emptyValue(kind);
        registry.defaults[id] = props.defaultValue !== undefined ? props.defaultValue : emptyValue(kind);
      } else if (props.value !== undefined) {
        registry.values[id] = props.value;
      }
    }
    const [, refresh] = React.useState(0);
    React.useImperativeHandle(ref, () => ({
      focus: () => bridge.notify({ t: "focus", id }),
      reset: () => {
        if (!registry) return;
        registry.values[id] = registry.defaults[id];
        refresh((n) => n + 1);
      },
    }));
    const rest = { ...props, kind };
    const children = rest.children;
    delete rest.children;
    if (registry && id) rest.value = registry.values[id];
    delete rest.defaultValue;
    return h("form-field", rest, children);
  });
  component.displayName = "Form." + kind;
  return component;
}

function revive(kind, value) {
  if (kind === "datepicker" && typeof value === "string") return new Date(value);
  return value;
}

/** Une valeur venue de Prism, au type du champ. */
function applyFormChange(formKey, id, raw) {
  const registry = forms.get(formKey);
  if (!registry) return;
  const kind = registry.kinds[id];
  const value = kind === "datepicker" ? (raw ? new Date(raw) : null) : raw;
  registry.values[id] = value;
  const field = registry.fields[id];
  if (field && field.storeValue) storeFormValue(commandKey(), id, value);
  if (field && typeof field.onChange === "function") field.onChange(value);
}

function formValues(registry) {
  return registry ? { ...registry.values } : {};
}

Form.TextField = formField("textfield");
Form.PasswordField = formField("password");
Form.TextArea = formField("textarea");
Form.Checkbox = formField("checkbox");
Form.DatePicker = formField("datepicker");
Form.DatePicker.Type = Object.freeze({ Date: "date", DateTime: "date_time" });
Form.DatePicker.isFullDay = (value) => value instanceof Date && value.getHours() === 0 && value.getMinutes() === 0;
Form.Dropdown = formField("dropdown");
Form.Dropdown.Item = hostComponent("dropdown-item");
Form.Dropdown.Section = hostComponent("dropdown-section");
Form.TagPicker = formField("tagpicker");
Form.TagPicker.Item = hostComponent("tagpicker-item");
Form.FilePicker = formField("filepicker");
Form.Description = hostComponent("form-description");
Form.Separator = hostComponent("form-separator");
Form.LinkAccessory = hostComponent("form-link");

// ——— Actions ———

function Action(props) {
  const rest = { ...props };
  delete rest.children;
  return h("action", rest);
}
Action.Style = Object.freeze({ Regular: "regular", Destructive: "destructive" });

Action.CopyToClipboard = function CopyToClipboard({ content, concealed, onCopy, title = "Copier dans le presse-papiers", icon = Icon.CopyClipboard, ...rest }) {
  return h(Action, {
    ...rest,
    title,
    icon,
    onAction: async () => {
      await Clipboard.copy(content, { concealed });
      if (onCopy) onCopy(content);
      await showHUD("Copié dans le presse-papiers");
    },
  });
};

Action.Paste = function Paste({ content, onPaste, title, icon = Icon.Clipboard, ...rest }) {
  return h(Action, {
    ...rest,
    title: title || "Coller dans l’app active",
    icon,
    onAction: async () => {
      await Clipboard.paste(content);
      if (onPaste) onPaste(content);
    },
  });
};

Action.OpenInBrowser = function OpenInBrowser({ url, onOpen, title = "Ouvrir dans le navigateur", icon = Icon.Globe, ...rest }) {
  return h(Action, {
    ...rest,
    title,
    icon,
    onAction: async () => {
      await open(url);
      if (onOpen) onOpen(url);
      await closeMainWindow();
    },
  });
};

Action.Open = function OpenAction({ target, application, onOpen, title, icon = Icon.Finder, ...rest }) {
  return h(Action, {
    ...rest,
    title: title || "Ouvrir",
    icon,
    onAction: async () => {
      await open(target, application);
      if (onOpen) onOpen(target);
      await closeMainWindow();
    },
  });
};

Action.OpenWith = function OpenWith({ path: target, onOpen, title = "Ouvrir avec…", icon = Icon.Upload, ...rest }) {
  return h(Action, {
    ...rest,
    title,
    icon,
    onAction: async () => {
      await bridge.request("openWith", { path: target });
      if (onOpen) onOpen(target);
    },
  });
};

Action.ShowInFinder = function ShowInFinder({ path: target, onShow, title = "Afficher dans le Finder", icon = Icon.Finder, ...rest }) {
  return h(Action, {
    ...rest,
    title,
    icon,
    onAction: async () => {
      await showInFinder(target);
      if (onShow) onShow(target);
      await closeMainWindow();
    },
  });
};

Action.Push = function Push({ target, onPush, onPop, title = "Ouvrir", icon, ...rest }) {
  const navigation = useNavigation();
  return h(Action, {
    ...rest,
    title,
    icon,
    onAction: () => {
      navigation.push(target, onPop);
      if (onPush) onPush();
    },
  });
};

Action.SubmitForm = function SubmitForm({ onSubmit, title = "Valider", icon = Icon.Checkmark, ...rest }) {
  const registry = React.useContext(FormContext);
  return h(Action, {
    ...rest,
    title,
    icon,
    submitsForm: true,
    onAction: () => (onSubmit ? onSubmit(formValues(registry)) : undefined),
  });
};

Action.Trash = function TrashAction({ paths, onTrash, title = "Mettre à la corbeille", icon = Icon.Trash, ...rest }) {
  return h(Action, {
    ...rest,
    title,
    icon,
    style: Action.Style.Destructive,
    onAction: async () => {
      await trash(paths);
      if (onTrash) onTrash(paths);
    },
  });
};

Action.CreateSnippet = function CreateSnippet({ snippet, title = "Créer un snippet", icon = Icon.Text, ...rest }) {
  return h(Action, { ...rest, title, icon, onAction: () => bridge.request("createSnippet", { snippet }) });
};

Action.CreateQuicklink = function CreateQuicklink({ quicklink, title = "Créer un lien rapide", icon = Icon.Link, ...rest }) {
  return h(Action, { ...rest, title, icon, onAction: () => bridge.request("createQuicklink", { quicklink }) });
};

Action.ToggleQuickLook = function ToggleQuickLook({ title = "Coup d’œil", icon = Icon.Eye, ...rest }) {
  return h(Action, { ...rest, title, icon, quickLook: true, onAction: () => bridge.request("quickLook", {}) });
};

Action.PickDate = function PickDate({ onChange, title = "Choisir une date", icon = Icon.Calendar, type, ...rest }) {
  return h(Action, {
    ...rest,
    title,
    icon,
    onAction: async () => {
      const picked = await bridge.request("pickDate", { title, type });
      if (onChange) onChange(picked ? new Date(picked) : null);
    },
  });
};
Action.PickDate.Type = Form.DatePicker.Type;
Action.PickDate.isFullDay = Form.DatePicker.isFullDay;

Action.InstallMCPServer = function InstallMCPServer({ server, title = "Installer le serveur MCP", icon = Icon.Plug, ...rest }) {
  return h(Action, { ...rest, title, icon, onAction: () => bridge.request("installMCPServer", { server }) });
};

const ActionPanel = hostComponent("action-panel");
ActionPanel.Section = hostComponent("action-section");
ActionPanel.Submenu = hostComponent("action-submenu");
ActionPanel.Item = Action;

// ——— Toasts, HUD, fenêtre ———

let nextToastID = 1;

class Toast {
  constructor(options) {
    this.id = nextToastID++;
    this._options = { style: Toast.Style.Success, ...options };
    this._visible = false;
  }
  get style() {
    return this._options.style;
  }
  set style(value) {
    this._options.style = value;
    this._update();
  }
  get title() {
    return this._options.title;
  }
  set title(value) {
    this._options.title = value;
    this._update();
  }
  get message() {
    return this._options.message;
  }
  set message(value) {
    this._options.message = value;
    this._update();
  }
  get primaryAction() {
    return this._options.primaryAction;
  }
  set primaryAction(value) {
    this._options.primaryAction = value;
    this._update();
  }
  get secondaryAction() {
    return this._options.secondaryAction;
  }
  set secondaryAction(value) {
    this._options.secondaryAction = value;
    this._update();
  }
  async show() {
    this._visible = true;
    await this._update();
  }
  async hide() {
    this._visible = false;
    await bridge.request("toast.hide", { id: this.id });
  }
  _update() {
    if (!this._visible) return Promise.resolve();
    const toast = this;
    const actions = ["primaryAction", "secondaryAction"].map((key) => {
      const action = toast._options[key];
      return action ? { title: action.title, onAction: () => action.onAction && action.onAction(toast) } : null;
    });
    return bridge.request("toast.show", {
      id: this.id,
      style: this._options.style,
      title: this._options.title,
      message: this._options.message,
      primaryAction: actions[0],
      secondaryAction: actions[1],
    });
  }
}
Toast.Style = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });

async function showToast(optionsOrStyle, title, message) {
  const options = typeof optionsOrStyle === "object" ? optionsOrStyle : { style: optionsOrStyle, title, message };
  const toast = new Toast(options);
  await toast.show();
  return toast;
}

const showHUD = (title, options = {}) => bridge.request("hud", { title, ...options });
const closeMainWindow = (options = {}) => bridge.request("closeMainWindow", options);
const popToRoot = (options = {}) => bridge.request("popToRoot", options);
const clearSearchBar = (options = {}) => bridge.request("clearSearchBar", options);

const Alert = {
  ActionStyle: Object.freeze({ Default: "default", Cancel: "cancel", Destructive: "destructive" }),
};

async function confirmAlert(options) {
  const confirmed = await bridge.request("alert", {
    title: options.title,
    message: options.message,
    icon: options.icon,
    primaryAction: options.primaryAction ? { title: options.primaryAction.title, style: options.primaryAction.style } : null,
    dismissAction: options.dismissAction ? { title: options.dismissAction.title } : null,
  });
  const action = confirmed ? options.primaryAction : options.dismissAction;
  if (action && action.onAction) action.onAction();
  return Boolean(confirmed);
}

// ——— Le Mac : fichiers, apps, sélection ———

function run(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, (error, stdout) => (error ? reject(error) : resolve(stdout)));
  });
}

async function open(target, application) {
  const args = [];
  if (application) {
    if (typeof application === "string") args.push(application.startsWith("/") ? "-a" : application.includes(".") && !application.includes(" ") ? "-b" : "-a", application);
    else if (application.path) args.push("-a", application.path);
    else if (application.bundleId) args.push("-b", application.bundleId);
  }
  args.push(String(target).replace(/^~(?=$|\/)/, os.homedir()));
  await run("/usr/bin/open", args);
}

const showInFinder = (target) => run("/usr/bin/open", ["-R", String(target).replace(/^~(?=$|\/)/, os.homedir())]).then(() => undefined);
const trash = (paths) => bridge.request("trash", { paths: (Array.isArray(paths) ? paths : [paths]).map(String) });
const getSelectedText = () =>
  bridge.request("selectedText", {}).then((text) => {
    if (typeof text !== "string" || text.length === 0) throw new Error("Aucun texte sélectionné");
    return text;
  });
const getSelectedFinderItems = () => bridge.request("selectedFinderItems", {});
const getFrontmostApplication = () => bridge.request("frontmostApplication", {});
const getApplications = (target) => bridge.request("applications", { path: target ? String(target) : null });
const getDefaultApplication = (target) => bridge.request("defaultApplication", { path: String(target) });
const launchCommand = (options) => bridge.request("launchCommand", options);
const updateCommandMetadata = (metadata) => bridge.request("updateCommandMetadata", metadata);
const openExtensionPreferences = () => bridge.request("openPreferences", { scope: "extension" });
const openCommandPreferences = () => bridge.request("openPreferences", { scope: "command" });
const captureException = (error) => console.error("captureException", error);

// ——— Presse-papiers ———

function clipboardContent(content) {
  if (typeof content === "string" || typeof content === "number") return { text: String(content) };
  return { text: content.text, file: content.file, html: content.html };
}

const Clipboard = {
  copy: (content, options = {}) => bridge.request("clipboard.copy", { ...clipboardContent(content), concealed: Boolean(options.concealed) }),
  paste: (content) => bridge.request("clipboard.paste", clipboardContent(content)),
  read: (options = {}) => bridge.request("clipboard.read", { offset: options.offset || 0 }),
  readText: async (options = {}) => (await Clipboard.read(options)).text,
  clear: () => bridge.request("clipboard.clear", {}),
};

// ——— Préférences et environnement ———

function getPreferenceValues() {
  return { ...bridge.session.preferences };
}

function supportDirectory() {
  const directory = bridge.session.environment.supportPath || path.join(os.tmpdir(), "prism-extension");
  fs.mkdirSync(directory, { recursive: true });
  return directory;
}

function commandKey() {
  return bridge.session.environment.commandName || "commande";
}

const environment = new Proxy(
  {},
  {
    get(_target, key) {
      if (key === "canAccess") return () => true;
      return bridge.session.environment[key];
    },
  },
);

// ——— Stockage ———

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
}

const localStorageFile = () => path.join(supportDirectory(), ".local-storage.json");

const LocalStorage = {
  allItems: async () => readJSON(localStorageFile()),
  getItem: async (key) => readJSON(localStorageFile())[key],
  setItem: async (key, value) => {
    const items = readJSON(localStorageFile());
    items[key] = value;
    writeJSON(localStorageFile(), items);
  },
  removeItem: async (key) => {
    const items = readJSON(localStorageFile());
    delete items[key];
    writeJSON(localStorageFile(), items);
  },
  clear: async () => writeJSON(localStorageFile(), {}),
};

class Cache {
  constructor(options = {}) {
    this.namespace = options.namespace || "default";
    this.capacity = options.capacity || 10 * 1024 * 1024;
    this.file = path.join(supportDirectory(), ".cache", this.namespace.replace(/[^\w.-]/g, "_") + ".json");
    this.subscribers = new Set();
    // Méthodes liées : `useSyncExternalStore(cache.subscribe, …)` les appelle sans l'objet.
    for (const name of ["get", "has", "set", "remove", "clear", "subscribe"]) this[name] = this[name].bind(this);
  }
  get storageDirectory() {
    return path.dirname(this.file);
  }
  _read() {
    return readJSON(this.file);
  }
  get(key) {
    const value = this._read()[key];
    return value === undefined ? undefined : value;
  }
  has(key) {
    return key in this._read();
  }
  get isEmpty() {
    return Object.keys(this._read()).length === 0;
  }
  set(key, data) {
    const items = this._read();
    items[key] = data;
    writeJSON(this.file, items);
    this.subscribers.forEach((subscriber) => subscriber(key, data));
  }
  remove(key) {
    const items = this._read();
    const existed = key in items;
    delete items[key];
    writeJSON(this.file, items);
    if (existed) this.subscribers.forEach((subscriber) => subscriber(key, undefined));
    return existed;
  }
  clear(options = { notifySubscribers: true }) {
    writeJSON(this.file, {});
    if (options.notifySubscribers) this.subscribers.forEach((subscriber) => subscriber(undefined, undefined));
  }
  subscribe(subscriber) {
    this.subscribers.add(subscriber);
    return () => this.subscribers.delete(subscriber);
  }
}

// ——— IA : les modèles de Prism ———

const AI = {
  Creativity: Object.freeze({ none: "none", low: "low", medium: "medium", high: "high", maximum: "maximum" }),
  Model: new Proxy({}, { get: (_target, key) => String(key) }),
  ask(prompt, options = {}) {
    const emitter = new EventEmitter();
    const promise = bridge.request("ai.ask", { prompt, creativity: options.creativity, model: options.model }).then((text) => {
      emitter.emit("data", text);
      return text;
    });
    promise.on = (event, listener) => {
      emitter.on(event, listener);
      return promise;
    };
    return promise;
  },
};

// ——— Navigateur et fenêtres : par Prism (AppleScript et accessibilité), sans l'extension de navigateur de Raycast ———

const BrowserExtension = {
  getTabs: () => bridge.request("browser.tabs", {}),
  getContent: (options = {}) =>
    bridge.request("browser.content", {
      format: options.format || "markdown",
      cssSelector: options.cssSelector,
      tabId: options.tabId === undefined ? undefined : String(options.tabId),
    }),
};

const WindowManagement = {
  DesktopType: Object.freeze({ User: "user", FullScreen: "fullscreen" }),
  getActiveWindow: () => bridge.request("windows.active", {}),
  getWindowsOnActiveDesktop: () => bridge.request("windows.list", {}),
  getDesktops: () => bridge.request("windows.desktops", {}),
  setWindowBounds: (options) => bridge.request("windows.setBounds", options),
};

/** OAuth : les jetons sont gardés dans le stockage local ; l'autorisation passe par le navigateur et le lien de retour de Prism. */
const OAuth = {
  RedirectMethod: Object.freeze({ Web: "web", App: "app", AppURI: "appURI" }),
  PKCEClient: class PKCEClient {
    constructor(options) {
      this.options = options;
      this.redirectMethod = options.redirectMethod;
      this.providerName = options.providerName;
      this.providerIcon = options.providerIcon;
      this.description = options.description;
      this.key = "oauth." + (options.providerId || options.providerName);
    }
    async authorizationRequest(options) {
      const crypto = require("crypto");
      const codeVerifier = crypto.randomBytes(48).toString("base64url");
      const codeChallenge = crypto.createHash("sha256").update(codeVerifier).digest("base64url");
      const state = crypto.randomBytes(16).toString("hex");
      const redirectURI = "prism://oauth";
      const request = { ...options, codeVerifier, codeChallenge, state, redirectURI };
      request.toURL = () => {
        const url = new URL(options.endpoint);
        url.searchParams.set("client_id", options.clientId);
        url.searchParams.set("response_type", "code");
        url.searchParams.set("redirect_uri", redirectURI);
        url.searchParams.set("scope", options.scope);
        url.searchParams.set("state", state);
        url.searchParams.set("code_challenge", codeChallenge);
        url.searchParams.set("code_challenge_method", "S256");
        for (const [key, value] of Object.entries(options.extraParameters || {})) url.searchParams.set(key, value);
        return url.toString();
      };
      return request;
    }
    async authorize(request) {
      const url = typeof request.toURL === "function" ? request.toURL() : request.url;
      const response = await bridge.request("oauth.authorize", { url, providerName: this.providerName });
      return { authorizationCode: response.code };
    }
    async setTokens(tokens) {
      const set = {
        accessToken: tokens.access_token || tokens.accessToken,
        refreshToken: tokens.refresh_token || tokens.refreshToken,
        idToken: tokens.id_token || tokens.idToken,
        scope: tokens.scope,
        expiresIn: tokens.expires_in || tokens.expiresIn,
        updatedAt: new Date().toISOString(),
      };
      await LocalStorage.setItem(this.key, JSON.stringify(set));
    }
    async getTokens() {
      const raw = await LocalStorage.getItem(this.key);
      if (!raw) return undefined;
      const set = JSON.parse(raw);
      const updatedAt = new Date(set.updatedAt);
      return {
        ...set,
        updatedAt,
        isExpired: () => Boolean(set.expiresIn) && Date.now() > updatedAt.getTime() + set.expiresIn * 1000 - 10000,
      };
    }
    async removeTokens() {
      await LocalStorage.removeItem(this.key);
    }
  },
};

// ——— Le module ———

module.exports = {
  bridge,
  applyFormChange,
  forms,
  NavigationContext,
  api: {
    AI,
    Action,
    ActionPanel,
    ActionPanelItem: Action,
    ActionPanelSection: ActionPanel.Section,
    ActionPanelSubmenu: ActionPanel.Submenu,
    Alert,
    AlertActionStyle: Alert.ActionStyle,
    BrowserExtension,
    Cache,
    Clipboard,
    Color,
    CopyToClipboardAction: Action.CopyToClipboard,
    Detail,
    Form,
    FormCheckbox: Form.Checkbox,
    FormDatePicker: Form.DatePicker,
    FormDropdown: Form.Dropdown,
    FormDropdownItem: Form.Dropdown.Item,
    FormDropdownSection: Form.Dropdown.Section,
    FormSeparator: Form.Separator,
    FormTagPicker: Form.TagPicker,
    FormTagPickerItem: Form.TagPicker.Item,
    FormTextArea: Form.TextArea,
    FormTextField: Form.TextField,
    Grid,
    Icon,
    Image,
    ImageMask: Image.Mask,
    Keyboard,
    LaunchType,
    List,
    ListItem: List.Item,
    ListSection: List.Section,
    LocalStorage,
    MenuBarExtra,
    OAuth,
    OpenAction: Action.Open,
    OpenInBrowserAction: Action.OpenInBrowser,
    OpenWithAction: Action.OpenWith,
    PasteAction: Action.Paste,
    PopToRootType,
    PushAction: Action.Push,
    ShowInFinderAction: Action.ShowInFinder,
    SubmitFormAction: Action.SubmitForm,
    Toast,
    ToastStyle: Toast.Style,
    Tool: {},
    TrashAction: Action.Trash,
    WindowManagement,
    allLocalStorageItems: LocalStorage.allItems,
    captureException,
    clearClipboard: Clipboard.clear,
    clearLocalStorage: LocalStorage.clear,
    clearSearchBar,
    closeMainWindow,
    confirmAlert,
    copyTextToClipboard: (text) => Clipboard.copy(text),
    environment,
    getApplications,
    getDefaultApplication,
    getFrontmostApplication,
    getLocalStorageItem: LocalStorage.getItem,
    getPreferenceValues,
    getSelectedFinderItems,
    getSelectedText,
    launchCommand,
    open,
    openCommandPreferences,
    openExtensionPreferences,
    pasteText: Clipboard.paste,
    popToRoot,
    get preferences() {
      return getPreferenceValues();
    },
    randomId: () => Math.random().toString(36).slice(2),
    removeLocalStorageItem: LocalStorage.removeItem,
    render: () => {},
    setLocalStorageItem: LocalStorage.setItem,
    showHUD,
    showInFinder,
    showToast,
    specialKeys: {},
    trash,
    unstable_AI: AI,
    updateCommandMetadata,
    useActionPanel: () => ({ update: () => {} }),
    useId: React.useId,
    useNavigation,
    useUnstableAI: () => undefined,
  },
};
