"use strict";
const { Form, ActionPanel, Action, showToast, Toast } = require("@raycast/api");
const { useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");

exports.default = function Command() {
  const [error, setError] = useState();
  return jsxs(Form, {
    actions: jsx(ActionPanel, {
      children: jsx(Action.SubmitForm, {
        title: "Envoyer",
        onSubmit: async (values) => {
          if (!values.name) return setError("Requis");
          await showToast({ style: Toast.Style.Success, title: "Envoyé", message: JSON.stringify(values) });
        },
      }),
    }),
    children: [
      jsx(Form.TextField, { id: "name", title: "Nom", placeholder: "Votre nom", error, onChange: () => setError(undefined) }),
      jsx(Form.Checkbox, { id: "subscribe", label: "S’abonner", defaultValue: true }),
      jsxs(Form.Dropdown, { id: "color", title: "Couleur", defaultValue: "blue", children: [jsx(Form.Dropdown.Item, { value: "red", title: "Rouge" }), jsx(Form.Dropdown.Item, { value: "blue", title: "Bleu" })] }),
      jsx(Form.DatePicker, { id: "when", title: "Quand" }),
    ],
  });
};
