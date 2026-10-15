"use strict";
const { showHUD, getPreferenceValues } = require("@raycast/api");
exports.default = async function Command(props) {
  await showHUD(`${getPreferenceValues().greeting}, ${props.arguments.who}`);
};
