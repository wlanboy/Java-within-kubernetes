package com.example.helloworld;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
class IndexController {

	// liefert die statische Seite aus src/main/resources/static/index.html
	@GetMapping("/")
	String index() {
		return "forward:/index.html";
	}

}
