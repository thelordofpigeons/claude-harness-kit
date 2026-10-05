// fixture: fully clean JSX. Token references, dvh sizing, IntersectionObserver,
// extreme weight contrast, focus-visible styling.
import React from "react";

export default function Hero() {
  const ref = React.useRef<HTMLElement>(null);

  React.useEffect(() => {
    const io = new IntersectionObserver(([entry]) => {
      entry.target.classList.toggle("is-visible", entry.isIntersecting);
    });
    if (ref.current) io.observe(ref.current);
    return () => io.disconnect();
  }, []);

  return (
    <section
      ref={ref}
      className="min-h-[100dvh] bg-[var(--color-bg)] text-[var(--color-ink)]"
    >
      <h1 className="font-black tracking-tighter">Ninety-nine percent craft</h1>
      <p className="font-light">Body copy set in the secondary face.</p>
      <a
        href="/work"
        className="underline decoration-[var(--color-accent)] transition-colors duration-200 focus-visible:outline-2"
      >
        See the work
      </a>
      <a href="#work">Jump to work</a>
      <button type="submit">Send</button>
      <button onClick={() => io.disconnect()}>Stop watching</button>
      <p>Body copy: set in the secondary face, no dashes needed.</p>
    </section>
  );
}
