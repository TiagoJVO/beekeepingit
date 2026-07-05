package problem

import (
	"log/slog"
	"net/http"
)

// RecoverMiddleware recovers panics from downstream handlers, logs them, and
// responds with a 500 Problem instead of a router's default plaintext panic
// response (or a stack trace leaking to the client).
func RecoverMiddleware(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logger.ErrorContext(r.Context(), "panic recovered", slog.Any("panic", rec))
					Write(w, r, Internal())
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
