interface LoadingProps {
  message: string;
}

export function Loading({ message }: LoadingProps) {
  return (
    <main className="page">
      <div className="card" role="status" aria-live="polite">
        <p>{message}</p>
      </div>
    </main>
  );
}
