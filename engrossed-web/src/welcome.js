// Shows the notice matching why the welcome page was opened, if it was opened
// because a click landed somewhere the reader cannot run.
const params = new URLSearchParams(location.search);
for (const reason of ["blocked", "pdf"]) {
  if (params.has(reason)) document.body.classList.add(reason);
}

// The page is written with the Mac shortcut. Everywhere else it is Ctrl+Shift+E.
const platform = navigator.userAgentData?.platform || navigator.platform || "";
if (!/mac/i.test(platform)) {
  const shortcut = document.getElementById("shortcut");
  if (shortcut) shortcut.textContent = "Ctrl+Shift+E";
}
