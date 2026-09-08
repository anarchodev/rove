export function handler({ kv }) {
    return "readonly: " + (kv.get("greeting") ?? "(unset)") + "\n";
}
