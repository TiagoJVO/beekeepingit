import { AuthProvider } from "react-oidc-context";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { readConfig } from "./config/env";
import { buildOidcConfig } from "./auth/oidcConfig";
import { AdminGuard } from "./auth/AdminGuard";
import { ConfigError } from "./components/ConfigError";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: false, refetchOnWindowFocus: false } },
});

export function App() {
  const { config, missing } = readConfig();

  // Misconfiguration surfaces as a clear screen instead of a blank page or a crash.
  if (!config) {
    return <ConfigError missing={missing} />;
  }

  return (
    <AuthProvider {...buildOidcConfig(config)}>
      <QueryClientProvider client={queryClient}>
        <AdminGuard config={config} />
      </QueryClientProvider>
    </AuthProvider>
  );
}
