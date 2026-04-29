export function handler() {
    return "readonly: " + (kv.get("greeting") ?? "(unset)") + "\n";
}
