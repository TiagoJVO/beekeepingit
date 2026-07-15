// Package servicetemplate wires together the shared building blocks —
// health, config, structured logging, OpenTelemetry, JWT auth, and the
// RFC 9457 error format — into an HTTP server every BeekeepingIT domain
// service bootstraps from. See example/main.go for the reference caller.
package servicetemplate

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/otelboot"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// Server is an HTTP server pre-wired with the shared middleware chain and
// unauthenticated /healthz//readyz endpoints; a caller mounts its own
// (typically JWT-protected) routes via Mount.
type Server struct {
	router     chi.Router
	httpServer *http.Server
	providers  *otelboot.Providers
	logger     *slog.Logger
}

// New assembles the router, middleware chain (OTel HTTP instrumentation,
// panic recovery, request ID, structured request logging) and health
// endpoints. checks may be nil, in which case an empty registry is used
// (readyz then always succeeds).
func New(cfg config.Config, providers *otelboot.Providers, logger *slog.Logger, checks *health.Registry) (*Server, error) {
	if cfg.ServiceName == "" {
		return nil, fmt.Errorf("servicetemplate: cfg.ServiceName is required")
	}
	if checks == nil {
		checks = health.NewRegistry()
	}

	r := chi.NewRouter()
	r.Use(otelhttp.NewMiddleware(cfg.ServiceName))
	r.Use(chimiddleware.RequestID)
	r.Use(problem.RecoverMiddleware(logger))
	r.Use(logging.RequestLogger(logger))

	r.Get("/healthz", checks.Healthz())
	r.Get("/readyz", checks.Readyz())

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
	}

	return &Server{router: r, httpServer: httpServer, providers: providers, logger: logger}, nil
}

// Mount registers h at pattern — e.g. a domain service's own routes wrapped
// in its JWT authn middleware. Use "/" to mount a whole API surface.
func (s *Server) Mount(pattern string, h http.Handler) {
	s.router.Mount(pattern, h)
}

// Router is an escape hatch for route registration beyond Mount.
func (s *Server) Router() chi.Router {
	return s.router
}

// Run starts the HTTP server and blocks until ctx is canceled or the
// process receives SIGINT/SIGTERM, then gracefully shuts down (draining
// in-flight requests, then flushing the OTel providers).
func (s *Server) Run(ctx context.Context) error {
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	serveErr := make(chan error, 1)
	go func() {
		s.logger.Info("http server listening", slog.String("addr", s.httpServer.Addr))
		if err := s.httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return s.Shutdown(shutdownCtx)
	}
}

// Shutdown gracefully drains in-flight requests, then flushes the OTel
// providers (if set).
func (s *Server) Shutdown(ctx context.Context) error {
	err := s.httpServer.Shutdown(ctx)
	if s.providers != nil {
		err = errors.Join(err, s.providers.Shutdown(ctx))
	}
	return err
}
