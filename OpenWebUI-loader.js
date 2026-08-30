(() => {
	'use strict';

	const INFO_BUTTON_SELECTOR = 'button[id^="info-"]';
	const BADGE_CLASS = 'portablellm-generation-speed';
	const SPEED_PATTERN = /\bpredicted_per_second\s*:\s*([0-9]+(?:\.[0-9]+)?)/i;

	let scanScheduled = false;

	function findTooltipHost(button) {
		let element = button;
		for (let depth = 0; element && depth < 4; depth += 1) {
			if (element._tippy?.props) {
				return element;
			}
			element = element.parentElement;
		}

		return null;
	}

	function readGenerationSpeed(button) {
		const tooltipHost = findTooltipHost(button);
		const content = tooltipHost?._tippy?.props?.content;
		let text = '';

		if (typeof content === 'string') {
			text = content;
		} else if (content instanceof Element) {
			text = content.textContent ?? '';
		}

		const match = text.match(SPEED_PATTERN);
		if (!match) {
			return null;
		}

		const speed = Number.parseFloat(match[1]);
		return Number.isFinite(speed) && speed > 0 ? speed : null;
	}

	function formatSpeed(speed) {
		if (speed >= 100) {
			return speed.toFixed(0);
		}
		if (speed >= 10) {
			return speed.toFixed(1);
		}
		return speed.toFixed(2);
	}

	function findBadge(buttonId) {
		return Array.from(document.querySelectorAll(`.${BADGE_CLASS}`)).find(
			(element) => element.dataset.infoButtonId === buttonId
		);
	}

	function updateSpeedBadge(button) {
		const speed = readGenerationSpeed(button);
		if (speed === null) {
			return false;
		}

		const formattedSpeed = formatSpeed(speed);
		let badge = findBadge(button.id);

		if (!badge) {
			const tooltipHost = findTooltipHost(button);
			if (!tooltipHost) {
				return false;
			}

			badge = document.createElement('span');
			badge.className = BADGE_CLASS;
			badge.dataset.infoButtonId = button.id;
			badge.style.cssText =
				'display:inline-flex;align-items:center;padding:0 0.375rem;font-size:0.75rem;line-height:1.25rem;color:inherit;opacity:0.65;white-space:nowrap;user-select:none;';
			tooltipHost.insertAdjacentElement('afterend', badge);
		}

		badge.textContent = `${formattedSpeed} tok/s`;
		badge.title = `Generation speed: ${speed.toFixed(2)} tokens/s`;
		badge.setAttribute('aria-label', badge.title);
		return true;
	}

	function scanInfoButtons() {
		scanScheduled = false;
		document.querySelectorAll(INFO_BUTTON_SELECTOR).forEach(updateSpeedBadge);
	}

	function scheduleScan() {
		if (scanScheduled) {
			return;
		}

		scanScheduled = true;
		window.requestAnimationFrame(scanInfoButtons);
	}

	function addedNodeContainsInfoButton(node) {
		return (
			node instanceof Element &&
			(node.matches(INFO_BUTTON_SELECTOR) || node.querySelector(INFO_BUTTON_SELECTOR) !== null)
		);
	}

	function startObserver() {
		const observer = new MutationObserver((mutations) => {
			if (
				mutations.some((mutation) =>
					Array.from(mutation.addedNodes).some(addedNodeContainsInfoButton)
				)
			) {
				scheduleScan();
				window.setTimeout(scheduleScan, 100);
			}
		});

		observer.observe(document.body, { childList: true, subtree: true });
		scheduleScan();
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', startObserver, { once: true });
	} else {
		startObserver();
	}
})();
