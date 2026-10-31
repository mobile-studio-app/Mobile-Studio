// Keeps a mostly vertical swipe from also scrolling the editor sideways. iOS locks the direction
// of a swipe only in native scroll views, not in a page's scrolling elements, so a slightly
// diagonal swipe through long lines drifted left and right. The first few points of movement
// decide: a vertical swipe keeps the horizontal position (through its momentum too); a
// sideways one scrolls freely, so long lines stay reachable.

const DECIDE_AFTER = 8;    // points of movement before choosing a direction
const SETTLE_MS = 160;     // momentum is over once the scroller is still this long

export function lockScrollDirection(scroller) {
  let startX = 0;
  let startY = 0;
  let lockedLeft = null;   // scrollLeft to hold, while a vertical swipe (and its momentum) lasts
  let decided = false;
  let touching = false;
  let settleTimer = 0;

  const release = () => { lockedLeft = null; };

  scroller.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) return;
    clearTimeout(settleTimer);
    touching = true;
    decided = false;
    lockedLeft = null;
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
  }, { passive: true });

  scroller.addEventListener('touchmove', (e) => {
    if (decided || e.touches.length !== 1) return;
    const dx = Math.abs(e.touches[0].clientX - startX);
    const dy = Math.abs(e.touches[0].clientY - startY);
    if (Math.max(dx, dy) < DECIDE_AFTER) return;
    decided = true;
    if (dy > dx) lockedLeft = scroller.scrollLeft;
  }, { passive: true });

  const end = () => {
    touching = false;
    clearTimeout(settleTimer);
    settleTimer = setTimeout(release, SETTLE_MS);
  };
  scroller.addEventListener('touchend', end, { passive: true });
  scroller.addEventListener('touchcancel', end, { passive: true });

  scroller.addEventListener('scroll', () => {
    if (lockedLeft === null) return;
    if (scroller.scrollLeft !== lockedLeft) scroller.scrollLeft = lockedLeft;
    // Momentum keeps scrolling after the finger lifts: hold until it stops.
    if (!touching) {
      clearTimeout(settleTimer);
      settleTimer = setTimeout(release, SETTLE_MS);
    }
  }, { passive: true });
}
