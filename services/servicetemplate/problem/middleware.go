package problem

import (
	"log/slog"
	"net/http"

	chimiddleware "github.com/go-chi/chi/v5/middleware"
)

// RecoverMiddleware recovers panics from downstream handlers, logs them, and
// responds with a 500 Problem instead of a router's default plaintext panic
// response (or a stack trace leaking to the client).
//
// It special-cases http.ErrAbortHandler: net/http uses that sentinel panic
// value as the documented way for a handler to abort a request (e.g. a
// streamed/partial response it can no longer complete) without net/http
// logging it as an unexpected panic. RecoverMiddleware must let it keep
// propagating unchanged — converting it into a 500 Problem would attempt to
// write a second, conflicting response over one that may already be
// partially written.
//
// Mount this behind chimiddleware.RequestID so a caught panic's log line
// carries the same request_id as the rest of that request's logs.
func RecoverMiddleware(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					if rec == http.ErrAbortHandler {
						panic(rec)
					}
					attrs := []any{slog.Any("panic", rec)}
					if id := chimiddleware.GetReqID(r.Context()); id != "" {
						attrs = append(attrs, slog.String("request_id", id))
					}
					logger.ErrorContext(r.Context(), "panic recovered", attrs...)
					Write(w, r, Internal())
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
