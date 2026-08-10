package com.example.helloworld;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
class HelloController {

	private final AtomicLong counter = new AtomicLong();
	private final ConcurrentHashMap<String, Long> idempotencyStore = new ConcurrentHashMap<>();

	@GetMapping("/hello")
	String hello() {
		return String.valueOf(counter.incrementAndGet());
	}

	// gleicher key liefert immer denselben, einmalig berechneten Wert zurueck
	// (Idempotency-Key-Pattern), statt bei jedem Aufruf neu hochzuzaehlen
	@GetMapping("/cpu")
	long cpu(@RequestParam String key) {
		return idempotencyStore.computeIfAbsent(key, k -> counter.incrementAndGet());
	}

}
