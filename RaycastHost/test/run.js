// Essais de l'hôte : il est lancé comme Prism le lance, sur l'extension de démonstration,
// et ce script joue le rôle de Prism (réponses aux requêtes, clics sur les actions, saisie).
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const assert = require("assert");

const host = path.join(__dirname, "..", "dist", "host.js");
const extension = path.join(__dirname, "fixtures", "demo");

function start(command, mode, extra = {}) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), "prism-host-test-"));
  const child = spawn(process.execPath, [host], { stdio: ["pipe", "pipe", "pipe"] });
  const session = { child, renders: [], requests: [], errors: [], exit: null, support, waiters: [] };
  let buffer = "";
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const message = JSON.parse(buffer.slice(0, index));
      buffer = buffer.slice(index + 1);
      if (message.t === "render") session.renders.push(message);
      if (message.t === "error") session.errors.push(message);
      if (message.t === "exit") session.exit = message.code;
      if (message.t === "request") {
        session.requests.push(message);
        const result = message.method === "selectedText" ? "texte" : null;
        send(session, { t: "response", rid: message.rid, result });
      }
      session.waiters = session.waiters.filter((waiter) => !waiter());
    }
  });
  child.stderr.on("data", () => {});
  send(session, {
    t: "launch",
    extensionPath: extension,
    command,
    mode,
    preferences: { greeting: "Salut" },
    environment: { supportPath: support, commandName: command, extensionName: "demo" },
    ...extra,
  });
  return session;
}

function send(session, message) {
  session.child.stdin.write(JSON.stringify(message) + "\n");
}

function until(session, predicate, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("délai dépassé : " + label)), 4000);
    const check = () => {
      const value = predicate();
      if (value) {
        clearTimeout(timer);
        resolve(value);
        return true;
      }
      return false;
    };
    if (!check()) session.waiters.push(check);
  });
}

const last = (session) => session.renders[session.renders.length - 1];
const find = (node, type) => {
  if (!node) return [];
  const found = node.type === type ? [node] : [];
  for (const child of node.children || []) found.push(...find(child, type));
  return found;
};
const actionsOf = (node) => find(find(node, "slot").find((slot) => slot.props.name === "actions"), "action");

let passed = 0;
async function test(name, body) {
  try {
    await body();
    passed += 1;
    console.log("✓ " + name);
  } catch (error) {
    console.log("✗ " + name + " : " + error.message);
    process.exitCode = 1;
  }
}

(async () => {
  await test("liste : rendu, accessoires, préférences, stockage local", async () => {
    const s = start("list", "view");
    const view = await until(s, () => { const r = last(s); return r && r.view && !r.view.props.isLoading && r.view; }, "liste chargée");
    assert.equal(view.type, "list");
    assert.equal(view.props.navigationTitle, "Salut (0)");
    const items = find(view, "list-item");
    assert.deepEqual(items.map((item) => item.props.title), ["Pomme", "Poire", "Prune"]);
    assert.equal(items[0].props.icon, "star-16");
    assert.equal(items[0].props.accessories[1].tag.color, "raycast-green");
    assert.equal(view.props.onSearchTextChange.$fn, "v0/list#0.onSearchTextChange");

    send(s, { t: "call", id: view.props.onSearchTextChange.$fn, args: ["po"] });
    await until(s, () => find(last(s).view, "list-item").length === 2, "filtrage par l'extension");

    const count = actionsOf(find(last(s).view, "list-item")[0]).find((action) => action.props.title === "Compter");
    assert.deepEqual(count.props.shortcut, { modifiers: ["cmd"], key: "k" });
    send(s, { t: "call", id: count.props.onAction.$fn, args: [] });
    await until(s, () => last(s).view.props.navigationTitle === "Salut (1)", "compteur");
    assert.equal(JSON.parse(fs.readFileSync(path.join(s.support, ".local-storage.json"), "utf8")).count, 1);
    s.child.kill();
  });

  await test("saisie rapide : chaque frappe atteint l'extension malgré les rendus intermédiaires", async () => {
    const s = start("list", "view");
    const view = await until(s, () => { const r = last(s); return r && r.view && !r.view.props.isLoading && r.view; }, "liste chargée");
    const id = view.props.onSearchTextChange.$fn;
    for (const prefix of ["p", "po", "poi", "poir"]) send(s, { t: "call", id, args: [prefix] });
    await until(s, () => find(last(s).view, "list-item").map((item) => item.props.title).join() === "Poire", "dernière frappe prise en compte");
    s.child.kill();
  });

  await test("navigation : Action.Push puis retour", async () => {
    const s = start("list", "view");
    await until(s, () => last(s) && last(s).view && !last(s).view.props.isLoading, "liste");
    const push = actionsOf(find(last(s).view, "list-item")[1])[0];
    send(s, { t: "call", id: push.props.onAction.$fn, args: [] });
    const detail = await until(s, () => last(s).depth === 2 && last(s).view.type === "detail" && last(s).view, "détail");
    assert.match(detail.props.markdown, /Poire/);
    assert.equal(find(detail, "metadata-label")[0].props.text, "Poire");
    send(s, { t: "pop" });
    await until(s, () => last(s).depth === 1 && last(s).view.type === "list", "retour à la liste");
    s.child.kill();
  });

  await test("presse-papiers et HUD par Prism", async () => {
    const s = start("list", "view");
    await until(s, () => last(s) && last(s).view && !last(s).view.props.isLoading, "liste");
    const copy = actionsOf(find(last(s).view, "list-item")[0]).find((action) => action.props.title === "Copier dans le presse-papiers");
    send(s, { t: "call", id: copy.props.onAction.$fn, args: [] });
    await until(s, () => s.requests.some((request) => request.method === "hud"), "HUD");
    const copied = s.requests.find((request) => request.method === "clipboard.copy");
    assert.equal(copied.params.text, "Pomme");
    s.child.kill();
  });

  await test("formulaire : valeurs, changement, envoi", async () => {
    const s = start("form", "view");
    const form = await until(s, () => last(s) && last(s).view, "formulaire");
    const fields = find(form, "form-field");
    assert.deepEqual(fields.map((field) => field.props.kind), ["textfield", "checkbox", "dropdown", "datepicker"]);
    assert.equal(fields[1].props.value, true);
    assert.equal(fields[2].props.value, "blue");
    const submit = actionsOf(form)[0];
    assert.equal(submit.props.submitsForm, true);
    send(s, { t: "call", id: submit.props.onAction.$fn, args: [] });
    await until(s, () => find(last(s).view, "form-field")[0].props.error === "Requis", "erreur de validation");
    send(s, { t: "formChange", formKey: form.props.formKey, id: "name", value: "Léa" });
    send(s, { t: "formChange", formKey: form.props.formKey, id: "when", value: "2026-10-16T08:00:00.000Z" });
    await until(s, () => find(last(s).view, "form-field")[0].props.error === undefined, "erreur effacée");
    const again = actionsOf(last(s).view)[0];
    send(s, { t: "call", id: again.props.onAction.$fn, args: [] });
    const toast = await until(s, () => s.requests.find((request) => request.method === "toast.show"), "toast");
    const values = JSON.parse(toast.params.message);
    assert.deepEqual(values, { name: "Léa", subscribe: true, color: "blue", when: "2026-10-16T08:00:00.000Z" });
    s.child.kill();
  });

  await test("commande sans vue : arguments et HUD, puis fin", async () => {
    const s = start("hud", "no-view", { arguments: { who: "Hugo" } });
    await until(s, () => s.exit !== null, "fin");
    assert.equal(s.exit, 0);
    assert.equal(s.requests.find((request) => request.method === "hud").params.title, "Salut, Hugo");
  });

  await test("erreur au chargement : signalée à Prism", async () => {
    const s = start("absente", "view");
    await until(s, () => s.errors.length > 0, "erreur");
    s.child.kill();
  });

  console.log(process.exitCode ? "Échec." : `Tout est vert (${passed} essais).`);
  process.exit();
})();
