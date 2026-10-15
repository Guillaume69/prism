// Hôte d'une commande d'extension Raycast, lancé par Prism : `node host.js`.
// Échanges en JSON, une ligne par message : Prism écrit sur l'entrée standard, l'hôte sur la sortie standard.
// Les `console.*` de l'extension partent sur la sortie d'erreur, que Prism garde dans un journal.
const Module = require("module");
const path = require("path");
const React = require("react");
const jsxRuntime = require("react/jsx-runtime");
const { createRenderer } = require("./reconciler");
const { api, bridge, applyFormChange, NavigationContext } = require("./api");

const output = process.stdout.write.bind(process.stdout);
function send(message) {
  output(JSON.stringify(message) + "\n");
}

for (const level of ["log", "info", "warn", "error", "debug", "trace"]) {
  console[level] = (...args) => process.stderr.write(`[${level}] ${args.map(describe).join(" ")}\n`);
}
process.stdout.write = (chunk, ...rest) => process.stderr.write(chunk, ...rest);

function describe(value) {
  if (value instanceof Error) return value.stack || value.message;
  if (typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }
  return String(value);
}

// ——— Modules fournis par l'hôte ———

const provided = {
  "@raycast/api": api,
  react: React,
  "react/jsx-runtime": jsxRuntime,
  "react/jsx-dev-runtime": jsxRuntime,
};
const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (Object.prototype.hasOwnProperty.call(provided, request)) return provided[request];
  return originalLoad.call(this, request, parent, isMain);
};

// ——— Requêtes vers Prism ———

let nextRequestID = 1;
const pending = new Map();

bridge.request = (method, params) =>
  new Promise((resolve, reject) => {
    const rid = nextRequestID++;
    pending.set(rid, { resolve, reject });
    send({ t: "request", rid, method, params: serialize(params, handlers.persistent, "") });
  });
bridge.notify = (message) => send(message);

// ——— Fonctions sérialisées ———
// Une fonction de l'interface est désignée par sa place (« list/list-item[Pomme]/slot[actions]/action[Copier]:onAction ») :
// l'extension recrée ses fonctions à chaque rendu, et un appel de Prism, parti avant le dernier rendu, doit
// atteindre la version courante. Les fonctions des requêtes (actions d'un toast) ont un numéro unique.

const handlers = { current: new Map(), previous: new Map(), persistent: new Map(), next: 1 };

function serialize(value, table, path) {
  if (value === null || value === undefined) return value === null ? null : undefined;
  if (typeof value === "function") {
    const id = table === handlers.persistent ? "r" + handlers.next++ : path;
    table.set(id, value);
    return { $fn: id };
  }
  if (value instanceof Date) return { $date: value.toISOString() };
  if (React.isValidElement(value)) return null;
  if (Array.isArray(value)) return value.map((item, index) => (item === undefined ? null : serialize(item, table, `${path}[${index}]`)));
  if (typeof value === "object") {
    const result = {};
    for (const [key, item] of Object.entries(value)) {
      if (key === "children" || item === undefined || typeof item === "symbol") continue;
      result[key] = serialize(item, table, `${path}.${key}`);
    }
    return result;
  }
  if (typeof value === "number" && !Number.isFinite(value)) return null;
  return value;
}

/** Le segment de chemin d'un nœud : son type, et ce qui le distingue de ses frères (id, titre, nom, valeur). */
function segment(node, index, seen) {
  const props = node.props || {};
  // La valeur ne désigne que les éléments d'un menu : celle d'un menu change quand on choisit.
  const label = props.id ?? props.name ?? (typeof props.title === "string" ? props.title : undefined) ?? (node.type.endsWith("-item") ? props.value : undefined);
  let base = label !== undefined ? `${node.type}[${String(label)}]` : `${node.type}#${index}`;
  const count = (seen.get(base) || 0) + 1;
  seen.set(base, count);
  if (count > 1) base += `~${count}`;
  return base;
}

function serializeNode(node, table, path) {
  if (node.hidden) return null;
  if (node.type === "#text") return { type: "#text", text: String(node.text) };
  const seen = new Map();
  return {
    type: node.type,
    props: serialize(node.props, table, path) || {},
    children: node.children
      .map((child, index) => serializeNode(child, table, child.type === "#text" ? path : `${path}/${segment(child, index, seen)}`))
      .filter(Boolean),
  };
}

// ——— Navigation : la pile des vues, toutes montées, la dernière affichée ———

const navigation = { depth: 1, pop: () => {}, popCallbacks: [] };

function NavigationRoot({ initial }) {
  const [stack, setStack] = React.useState([{ element: initial, onPop: null }]);
  const value = React.useMemo(
    () => ({
      push: (element, onPop) => setStack((current) => [...current, { element, onPop }]),
      pop: () =>
        setStack((current) => {
          if (current.length <= 1) return current;
          const top = current[current.length - 1];
          if (top.onPop) setTimeout(top.onPop, 0);
          return current.slice(0, -1);
        }),
    }),
    [],
  );
  navigation.depth = stack.length;
  navigation.pop = value.pop;
  return React.createElement(
    NavigationContext.Provider,
    { value },
    stack.map((entry, index) => React.createElement("nav-entry", { key: index, index, active: index === stack.length - 1 }, entry.element)),
  );
}

// ——— Rendu ———

const container = { children: [] };
let renderScheduled = false;

const renderer = createRenderer(() => {
  if (renderScheduled) return;
  renderScheduled = true;
  setImmediate(flush);
});

function flush() {
  renderScheduled = false;
  const entries = [];
  collect(container, entries);
  const active = entries.find((entry) => entry.props.active) || entries[entries.length - 1];
  handlers.previous = handlers.current;
  handlers.current = new Map();
  const prefix = active ? `v${active.props.index}` : "v";
  const view = active ? active.children.map((child, index) => serializeNode(child, handlers.current, `${prefix}/${segment(child, index, new Map())}`)).filter(Boolean)[0] || null : null;
  send({ t: "render", depth: navigation.depth, view });
}

function collect(node, entries) {
  for (const child of node.children) {
    if (child.type === "nav-entry") entries.push(child);
    else collect(child, entries);
  }
}

function reportError(error) {
  const message = error && error.message ? error.message : String(error);
  send({ t: "error", message, stack: error && error.stack ? String(error.stack) : "" });
}

class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error) {
    return { error };
  }
  componentDidCatch(error) {
    reportError(error);
  }
  render() {
    if (this.state.error) {
      const error = this.state.error;
      return React.createElement(api.Detail, {
        markdown: "## Erreur dans l’extension\n\n```\n" + (error.stack || error.message || String(error)) + "\n```",
      });
    }
    return this.props.children;
  }
}

// ——— Lancement ———

async function launch(message) {
  bridge.session = {
    preferences: message.preferences || {},
    environment: message.environment || {},
  };
  const file = path.join(message.extensionPath, message.command + ".js");
  let exported;
  try {
    exported = require(file);
  } catch (error) {
    reportError(error);
    return;
  }
  const command = exported && exported.default ? exported.default : exported;
  const props = {
    arguments: message.arguments || {},
    launchType: message.launchType || "userInitiated",
    launchContext: message.launchContext,
    fallbackText: message.fallbackText,
  };
  if (message.mode === "no-view") {
    try {
      await command(props);
      send({ t: "exit", code: 0 });
    } catch (error) {
      reportError(error);
      send({ t: "exit", code: 1 });
    }
    return;
  }
  const initial = React.createElement(ErrorBoundary, null, React.createElement(command, props));
  renderer.render(React.createElement(NavigationRoot, { initial }), container, reportError);
}

// ——— Messages de Prism ———

function call(id, args) {
  const fn = handlers.current.get(id) || handlers.previous.get(id) || handlers.persistent.get(id);
  if (!fn) return;
  try {
    const result = fn(...(args || []).map(reviveArgument));
    if (result && typeof result.catch === "function") result.catch(reportError);
  } catch (error) {
    reportError(error);
  }
}

function reviveArgument(value) {
  if (value && typeof value === "object" && typeof value.$date === "string") return new Date(value.$date);
  return value;
}

function revive(value) {
  if (Array.isArray(value)) return value.map(revive);
  if (value && typeof value === "object") {
    if (typeof value.$date === "string") return new Date(value.$date);
    const result = {};
    for (const [key, item] of Object.entries(value)) result[key] = revive(item);
    return result;
  }
  return value;
}

function handle(message) {
  switch (message.t) {
    case "launch":
      launch(message);
      break;
    case "call":
      call(message.id, message.args);
      break;
    case "response": {
      const request = pending.get(message.rid);
      if (!request) break;
      pending.delete(message.rid);
      if (message.error) request.reject(new Error(message.error));
      else request.resolve(revive(message.result));
      break;
    }
    case "formChange":
      try {
        applyFormChange(message.formKey, message.id, message.value);
      } catch (error) {
        reportError(error);
      }
      break;
    case "pop":
      navigation.pop();
      break;
    case "quit":
      renderer.unmount(container);
      setTimeout(() => process.exit(0), 20);
      break;
    default:
      break;
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (!line.trim()) continue;
    try {
      handle(JSON.parse(line));
    } catch (error) {
      reportError(error);
    }
  }
});
process.stdin.on("end", () => process.exit(0));
process.on("uncaughtException", reportError);
process.on("unhandledRejection", reportError);

send({ t: "ready" });
