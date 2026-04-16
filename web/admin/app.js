// rove admin entry point — router + mount live in M2.
import { api } from "./api.js";

const root = document.getElementById("app");
root.textContent = "rove admin (scaffold — M2 wires up routing).";

window.__rove_api = api;
