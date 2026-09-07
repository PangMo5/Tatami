// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
(() => {
  document.querySelectorAll('[data-language-picker]').forEach(picker => {
    picker.addEventListener('change', () => {
      const target = new URL(picker.value, location.href);
      target.hash = location.hash;
      location.assign(target);
    });
  });
  document.querySelectorAll('[data-language-link]').forEach(link => link.addEventListener('click', () => {
    const target = new URL(link.href); target.hash = location.hash; link.href = target.href;
  }));
  document.querySelectorAll('[data-copy-command]').forEach(button => {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copyCommand);
        const label = button.textContent;
        button.textContent = button.dataset.copiedLabel;
        setTimeout(() => { button.textContent = label; }, 1800);
      } catch { button.textContent = button.dataset.copyError; }
    });
  });
  document.querySelectorAll('.nav-links a').forEach(link => link.addEventListener('click', () => {
    const toggle = document.getElementById('nav-toggle');
    if (toggle) toggle.checked = false;
  }));
})();
