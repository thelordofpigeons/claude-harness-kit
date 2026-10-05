// fixture: intentionally slop-ridden JSX. Every hit here is on purpose.
import React from "react";

export default function Hero() {
  React.useEffect(() => {
    const onScroll = () => {};
    window.addEventListener("scroll", onScroll);
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <section className="h-screen transition-all bg-gradient-to-r from-purple-500 via-violet-500 to-indigo-600">
      <h2 className="italic font-inter" style={{ color: "#fff" }}>
        Ship faster with AI
      </h2>
      <button className="hover:scale-105">Get started</button>
      <button className="hover:scale-105">Learn more</button>
      <button className="hover:scale-110">Contact us</button>
      <a href="#">Pricing</a>
      <a href="">Docs</a>
      <a href="javascript:void(0)">Blog</a>
      <p>Trusted by teams everywhere.</p>
    </section>
  );
}
