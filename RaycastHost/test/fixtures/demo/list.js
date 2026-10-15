"use strict";
const { List, ActionPanel, Action, Detail, Icon, Color, LocalStorage, useNavigation, getPreferenceValues } = require("@raycast/api");
const { useState, useEffect } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");

function Page({ name }) {
  const { pop } = useNavigation();
  return jsx(Detail, {
    markdown: `# ${name}\n\nPage poussée.`,
    navigationTitle: name,
    metadata: jsx(Detail.Metadata, { children: jsx(Detail.Metadata.Label, { title: "Nom", text: name }) }),
    actions: jsx(ActionPanel, { children: jsx(Action, { title: "Revenir", onAction: pop }) }),
  });
}

exports.default = function Command() {
  const [text, setText] = useState("");
  const [count, setCount] = useState(0);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    LocalStorage.getItem("count").then((value) => {
      setCount(Number(value || 0));
      setLoading(false);
    });
  }, []);
  const greeting = getPreferenceValues().greeting;
  const fruits = ["Pomme", "Poire", "Prune"].filter((fruit) => fruit.toLowerCase().includes(text.toLowerCase()));
  return jsxs(List, {
    isLoading: loading,
    searchBarPlaceholder: "Chercher un fruit",
    onSearchTextChange: setText,
    navigationTitle: `${greeting} (${count})`,
    children: [
      jsx(List.Section, {
        title: "Fruits",
        children: fruits.map((fruit) =>
          jsx(List.Item, {
            id: fruit,
            title: fruit,
            subtitle: "fruit",
            icon: Icon.Star,
            accessories: [{ text: "frais" }, { tag: { value: "bio", color: Color.Green } }],
            actions: jsxs(ActionPanel, {
              children: [
                jsx(Action.Push, { title: "Ouvrir", target: jsx(Page, { name: fruit }) }),
                jsx(Action, {
                  title: "Compter",
                  shortcut: { modifiers: ["cmd"], key: "k" },
                  onAction: async () => {
                    await LocalStorage.setItem("count", count + 1);
                    setCount(count + 1);
                  },
                }),
                jsx(Action.CopyToClipboard, { content: fruit }),
              ],
            }),
          }, fruit)
        ),
      }),
    ],
  });
};
