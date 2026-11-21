import { describe, it, expect } from "vitest";
import { isBackendConfigured } from "@/lib/env";
describe("isBackendConfigured", () => {
  it("requires a real key and a valid https/local URL", () => {
    expect(isBackendConfigured({})).toBe(false);
    expect(isBackendConfigured({ NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co", NEXT_PUBLIC_SUPABASE_ANON_KEY: "k" })).toBe(true);
    expect(isBackendConfigured({ NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:54321", NEXT_PUBLIC_SUPABASE_ANON_KEY: "k" })).toBe(true);
    expect(isBackendConfigured({ NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co", NEXT_PUBLIC_SUPABASE_ANON_KEY: "dummy" })).toBe(false);
    expect(isBackendConfigured({ NEXT_PUBLIC_SUPABASE_URL: "http://evil.example.com", NEXT_PUBLIC_SUPABASE_ANON_KEY: "k" })).toBe(false);
    expect(isBackendConfigured({ NEXT_PUBLIC_SUPABASE_URL: "not a url", NEXT_PUBLIC_SUPABASE_ANON_KEY: "k" })).toBe(false);
  });
});
