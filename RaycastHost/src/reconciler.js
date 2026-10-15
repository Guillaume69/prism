// Le réconciliateur : React construit un arbre d'objets simples (type, props, enfants),
// que l'hôte sérialise en JSON pour Prism après chaque mise à jour validée.
const Reconciler = require("react-reconciler");
const { DefaultEventPriority } = require("react-reconciler/constants");
const React = require("react");

let currentUpdatePriority = 0;

function createRenderer(onCommit) {
  const config = {
    supportsMutation: true,
    supportsPersistence: false,
    supportsHydration: false,
    isPrimaryRenderer: true,
    supportsMicrotasks: true,
    scheduleMicrotask: queueMicrotask,
    scheduleTimeout: setTimeout,
    cancelTimeout: clearTimeout,
    noTimeout: -1,
    NotPendingTransition: null,
    HostTransitionContext: React.createContext(null),

    createInstance(type, props) {
      return { type, props, children: [], hidden: false };
    },
    createTextInstance(text) {
      return { type: "#text", text, children: [], hidden: false };
    },
    appendInitialChild(parent, child) {
      parent.children.push(child);
    },
    finalizeInitialChildren() {
      return false;
    },
    shouldSetTextContent() {
      return false;
    },
    getRootHostContext() {
      return {};
    },
    getChildHostContext(parent) {
      return parent;
    },
    getPublicInstance(instance) {
      return instance;
    },
    prepareForCommit() {
      return null;
    },
    resetAfterCommit(container) {
      onCommit(container);
    },
    preparePortalMount() {},
    appendChild(parent, child) {
      remove(parent.children, child);
      parent.children.push(child);
    },
    appendChildToContainer(container, child) {
      remove(container.children, child);
      container.children.push(child);
    },
    insertBefore(parent, child, before) {
      remove(parent.children, child);
      parent.children.splice(Math.max(parent.children.indexOf(before), 0), 0, child);
    },
    insertInContainerBefore(container, child, before) {
      remove(container.children, child);
      container.children.splice(Math.max(container.children.indexOf(before), 0), 0, child);
    },
    removeChild(parent, child) {
      remove(parent.children, child);
    },
    removeChildFromContainer(container, child) {
      remove(container.children, child);
    },
    commitUpdate(instance, _type, _oldProps, newProps) {
      instance.props = newProps;
    },
    commitTextUpdate(textInstance, _oldText, newText) {
      textInstance.text = newText;
    },
    resetTextContent() {},
    clearContainer(container) {
      container.children.length = 0;
    },
    hideInstance(instance) {
      instance.hidden = true;
    },
    unhideInstance(instance) {
      instance.hidden = false;
    },
    hideTextInstance(instance) {
      instance.hidden = true;
    },
    unhideTextInstance(instance) {
      instance.hidden = false;
    },
    detachDeletedInstance() {},
    getInstanceFromNode() {
      return null;
    },
    beforeActiveInstanceBlur() {},
    afterActiveInstanceBlur() {},
    prepareScopeUpdate() {},
    getInstanceFromScope() {
      return null;
    },
    setCurrentUpdatePriority(priority) {
      currentUpdatePriority = priority;
    },
    getCurrentUpdatePriority() {
      return currentUpdatePriority;
    },
    resolveUpdatePriority() {
      return currentUpdatePriority || DefaultEventPriority;
    },
    shouldAttemptEagerTransition() {
      return false;
    },
    trackSchedulerEvent() {},
    resolveEventType() {
      return null;
    },
    resolveEventTimeStamp() {
      return -1.1;
    },
    requestPostPaintCallback() {},
    maySuspendCommit() {
      return false;
    },
    preloadInstance() {
      return true;
    },
    startSuspendingCommit() {},
    suspendInstance() {},
    waitForCommitToBeReady() {
      return null;
    },
    resetFormInstance() {},
    bindToConsole() {
      return console.error.bind(console);
    },
  };

  const reconciler = Reconciler(config);
  return {
    render(element, container, onError) {
      if (!container.root) {
        container.root = reconciler.createContainer(
          container,
          0, // racine « legacy » : rendu synchrone, comme l'hôte de Raycast
          null,
          false,
          null,
          "",
          onError,
          onError,
          onError,
          null,
        );
      }
      reconciler.updateContainer(element, container.root, null, null);
    },
    unmount(container) {
      if (container.root) reconciler.updateContainer(null, container.root, null, null);
    },
  };
}

function remove(list, item) {
  const index = list.indexOf(item);
  if (index >= 0) list.splice(index, 1);
}

module.exports = { createRenderer };
