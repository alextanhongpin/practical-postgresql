pandock := docker run --rm -v "$(PWD):/data" -u $(shell id -u):$(shell id -g) --platform=linux/x86_64 pandoc/extra
# Makefile for converting all Markdown files in samples/ to HTML using pandoc

# Find all .md files in samples/ and convert each to .html
convert:
	find samples -name '*.md' | while read file; do \
	  $(pandock) "$$file" -o "$${file%.md}.html" --css=assets/css/style.css --embed-resources --standalone; \
	done

# Clean all generated .html files in samples/
clean:
	find samples -name '*.html' -delete

.PHONY: convert clean
