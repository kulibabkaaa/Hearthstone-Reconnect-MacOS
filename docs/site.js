(() => {
  "use strict";
  const config = window.HS_SITE || {};
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const header = document.querySelector(".site-header");

  // Give the floating header a firmer surface only when content moves under it.
  const syncHeader = () =>
    header?.classList.toggle("is-scrolled", scrollY > 24);
  syncHeader();
  addEventListener("scroll", syncHeader, { passive: true });

  // Ease the full card and page into place while preserving native details
  // semantics for keyboard and assistive-technology users.
  const faqItems = [...document.querySelectorAll(".faq-list details")];
  faqItems.forEach((details) => {
    const summary = details.querySelector("summary");
    const answer = details.querySelector(".faq-answer");
    let heightAnimation;

    const setExpanded = (expanded, animate = true) => {
      heightAnimation?.cancel();
      const startHeight = details.offsetHeight;

      if (expanded) {
        details.classList.remove("is-closing");
        details.open = true;
      } else {
        details.classList.add("is-closing");
      }

      if (!animate || reduceMotion.matches || !Element.prototype.animate) {
        details.open = expanded;
        details.classList.remove("is-closing");
        details.style.removeProperty("height");
        details.style.removeProperty("overflow");
        return;
      }

      const endHeight = expanded
        ? summary.offsetHeight + answer.offsetHeight
        : summary.offsetHeight;
      details.style.height = `${startHeight}px`;
      details.style.overflow = "hidden";
      heightAnimation = details.animate(
        { height: [`${startHeight}px`, `${endHeight}px`] },
        { duration: 360, easing: "cubic-bezier(0.22, 1, 0.36, 1)" },
      );
      heightAnimation.onfinish = () => {
        details.open = expanded;
        details.classList.remove("is-closing");
        details.style.removeProperty("height");
        details.style.removeProperty("overflow");
        heightAnimation = null;
      };
    };

    summary.addEventListener("click", (event) => {
      event.preventDefault();
      const shouldExpand =
        !details.open || details.classList.contains("is-closing");
      setExpanded(shouldExpand);
    });

    details.openFaq = setExpanded;
  });

  // Preserve the existing /#install entry point within the four-question FAQ.
  const openSetup = () => {
    if (location.hash === "#install") {
      const setup = document.querySelector("#install");
      setup.openFaq?.(true, false);
    }
  };
  openSetup();
  addEventListener("hashchange", openSetup);

  // Odometer-style rolling digits. The readable value is present even without JS.
  const statElements = [...document.querySelectorAll("[data-number]")];
  const finishNumber = (element) => {
    element
      .querySelector(".number-readable")
      .classList.remove("reel-accessible");
    element.querySelector(".reel-number")?.remove();
  };
  function rollNumber(element) {
    if (element.dataset.animated) return;
    element.dataset.animated = "true";
    if (reduceMotion.matches || !Element.prototype.animate) return;
    const readable = element.querySelector(".number-readable");
    const reels = document.createElement("span");
    reels.className = "reel-number is-rolling";
    reels.setAttribute("aria-hidden", "true");
    const animations = [];
    for (const [index, character] of [...element.dataset.number].entries()) {
      if (!/\d/.test(character)) {
        reels.append(character);
        continue;
      }
      const windowElement = document.createElement("span");
      windowElement.className = "digit-window";
      const track = document.createElement("span");
      track.className = "digit-track";
      // One complete turn gives every column motion, including digits that
      // finish on zero, before landing directly on the requested value.
      const last = 10 + Number(character);
      for (let digit = 0; digit <= last; digit++) {
        const cell = document.createElement("span");
        cell.textContent = String(digit % 10);
        track.append(cell);
      }
      windowElement.append(track);
      reels.append(windowElement);
      animations.push({ track, index, last });
    }
    readable.classList.add("reel-accessible");
    element.append(reels);
    const runs = animations.map(({ track, index, last }) => ({
      track,
      last,
      animation: track.animate(
        [
          { transform: "translateY(0)" },
          { transform: `translateY(-${last * 1.08}em)` },
        ],
        {
          duration: 1500 + index * 150,
          easing: "cubic-bezier(.16,1,.3,1)",
          fill: "forwards",
        },
      ),
    }));
    Promise.all(runs.map(({ animation }) => animation.finished))
      .then(() => {
        // Keep the reel itself in its final position. Replacing it with the
        // fallback text changed glyph widths and caused a visible end snap.
        runs.forEach(({ track, last, animation }) => {
          track.style.transform = `translateY(-${last * 1.08}em)`;
          animation.cancel();
        });
        reels.classList.remove("is-rolling");
      })
      .catch(() => finishNumber(element));
  }
  if ("IntersectionObserver" in window) {
    const statsObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          rollNumber(entry.target);
          statsObserver.unobserve(entry.target);
        });
      },
      { threshold: 0.65 },
    );
    statElements.forEach((element) => statsObserver.observe(element));
  }
  reduceMotion.addEventListener("change", () => {
    if (reduceMotion.matches) statElements.forEach(finishNumber);
  });

  // Reveal supporting content as it enters the viewport. The hero and sticky
  // feature cards keep their existing layout; only their contents ease in.
  const revealItems = [
    ...document.querySelectorAll(
      ".community > *, .feature-media, .feature-copy, .stat-card, .faq-intro, .faq-list, .footer-inner > *",
    ),
  ];
  if (!reduceMotion.matches && "IntersectionObserver" in window) {
    revealItems.forEach((element, index) => {
      element.classList.add("reveal-item");
      element.style.setProperty("--reveal-order", index % 3);
    });
    const revealObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          revealObserver.unobserve(entry.target);
        });
      },
      { threshold: 0.14, rootMargin: "0px 0px -6%" },
    );
    revealItems.forEach((element) => revealObserver.observe(element));
    reduceMotion.addEventListener("change", () => {
      if (!reduceMotion.matches) return;
      revealItems.forEach((element) => element.classList.add("is-visible"));
      revealObserver.disconnect();
    });
  }

  // Play the overview clip only while it is in view. Failed media shows its poster.
  document.querySelectorAll("[data-media]").forEach((slot) => {
    const source = config.videos?.[slot.dataset.media];
    if (!source) return;
    const video = slot.querySelector("video");
    const toggle = slot.querySelector(".media-toggle");
    let userPaused = false;
    let onScreen = false;
    const syncButton = () => {
      toggle.textContent = video.paused ? "Play" : "Pause";
      toggle.setAttribute(
        "aria-label",
        `${video.paused ? "Play" : "Pause"} ${slot.dataset.media} video`,
      );
    };
    const play = () => video.play().catch(syncButton);
    video.src = source;
    video.preload = "metadata";
    video.addEventListener("loadeddata", () => {
      slot.classList.add("has-video");
      video.hidden = false;
      toggle.hidden = false;
      if (onScreen && !reduceMotion.matches && !userPaused) play();
      syncButton();
    });
    video.addEventListener("error", () => {
      video.pause();
      slot.classList.remove("has-video");
      video.hidden = true;
      toggle.hidden = true;
    });
    video.addEventListener("play", syncButton);
    video.addEventListener("pause", syncButton);
    toggle.addEventListener("click", () => {
      userPaused = !video.paused;
      if (video.paused) play();
      else video.pause();
    });
    if ("IntersectionObserver" in window) {
      const observer = new IntersectionObserver(
        (entries) => {
          onScreen = entries[0].isIntersecting;
          if (onScreen && !reduceMotion.matches && !userPaused) play();
          else video.pause();
        },
        { threshold: 0.25 },
      );
      observer.observe(slot);
    }
    reduceMotion.addEventListener("change", () => {
      if (reduceMotion.matches) video.pause();
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) video.pause();
      else if (onScreen && !reduceMotion.matches && !userPaused) play();
    });
  });
})();
