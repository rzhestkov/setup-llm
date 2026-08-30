(() => {
	'use strict';

	const INFO_BUTTON_SELECTOR = 'button[id^="info-"]';
	const BADGE_CLASS = 'portablellm-response-metrics';
	const SPEED_PATTERN = /\bpredicted_per_second\s*:\s*([0-9]+(?:\.[0-9]+)?)/i;
	const TOTAL_TOKENS_PATTERN = /\btotal_tokens\s*:\s*([0-9]+)/i;
	const INPUT_TOKENS_PATTERN = /\binput_tokens\s*:\s*([0-9]+)/i;
	const OUTPUT_TOKENS_PATTERN = /\boutput_tokens\s*:\s*([0-9]+)/i;
	const RUNTIME_CONFIG_URL = '/static/portablellm-runtime.json';
	const RUNTIME_CONFIG_REFRESH_MS = 1000;

	let scanScheduled = false;
	let runtimeConfigRequest = null;
	let runtimeConfigLoadedAt = 0;
	let runtimeContextSize = null;

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

	function readTooltipText(button) {
		const tooltipHost = findTooltipHost(button);
		const content = tooltipHost?._tippy?.props?.content;

		if (typeof content === 'string') {
			return content;
		}
		if (content instanceof Element) {
			return content.textContent ?? '';
		}

		return '';
	}

	function readNumber(text, pattern) {
		const match = text.match(pattern);
		if (!match) {
			return null;
		}

		const value = Number.parseFloat(match[1]);
		return Number.isFinite(value) && value >= 0 ? value : null;
	}

	function readResponseMetrics(button) {
		const text = readTooltipText(button);
		const speed = readNumber(text, SPEED_PATTERN);
		let totalTokens = readNumber(text, TOTAL_TOKENS_PATTERN);

		if (totalTokens === null) {
			const inputTokens = readNumber(text, INPUT_TOKENS_PATTERN);
			const outputTokens = readNumber(text, OUTPUT_TOKENS_PATTERN);
			if (inputTokens !== null && outputTokens !== null) {
				totalTokens = inputTokens + outputTokens;
			}
		}

		return {
			speed: speed !== null && speed > 0 ? speed : null,
			totalTokens
		};
	}

	async function refreshRuntimeConfig() {
		const now = Date.now();
		if (runtimeConfigRequest) {
			return runtimeConfigRequest;
		}
		if (now - runtimeConfigLoadedAt < RUNTIME_CONFIG_REFRESH_MS) {
			return runtimeContextSize;
		}

		runtimeConfigLoadedAt = now;
		runtimeConfigRequest = fetch(`${RUNTIME_CONFIG_URL}?t=${now}`, { cache: 'no-store' })
			.then((response) => {
				if (!response.ok) {
					throw new Error(`HTTP ${response.status}`);
				}
				return response.json();
			})
			.then((config) => {
				const contextSize = Number.parseInt(config.contextSize, 10);
				if (Number.isFinite(contextSize) && contextSize > 0) {
					runtimeContextSize = contextSize;
				}
				return runtimeContextSize;
			})
			.catch(() => runtimeContextSize)
			.finally(() => {
				runtimeConfigRequest = null;
			});

		return runtimeConfigRequest;
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

	function updateMetricsBadge(button) {
		const metrics = readResponseMetrics(button);
		const labels = [];
		const details = [];

		if (metrics.totalTokens !== null && runtimeContextSize !== null) {
			const usedTokens = Math.round(metrics.totalTokens);
			labels.push(`${usedTokens}/${runtimeContextSize} ctx`);
			const usagePercent = (usedTokens / runtimeContextSize) * 100;
			details.push(
				`Context: ${usedTokens}/${runtimeContextSize} tokens (${usagePercent.toFixed(1)}%)`
			);
		}

		if (metrics.speed !== null) {
			labels.push(`${formatSpeed(metrics.speed)} tok/s`);
			details.push(`Generation speed: ${metrics.speed.toFixed(2)} tokens/s`);
		}

		if (labels.length === 0) {
			return false;
		}

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

		badge.textContent = labels.join(' \u00b7 ');
		badge.title = details.join('; ');
		badge.setAttribute('aria-label', badge.title);
		return true;
	}

	async function scanInfoButtons() {
		scanScheduled = false;
		await refreshRuntimeConfig();
		document.querySelectorAll(INFO_BUTTON_SELECTOR).forEach(updateMetricsBadge);
	}

	function scheduleScan() {
		if (scanScheduled) {
			return;
		}

		scanScheduled = true;
		window.requestAnimationFrame(() => {
			void scanInfoButtons();
		});
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
