.PHONY: test clean help

# Default target
all: test

# Run tests using plenary
test:
	@echo "Running nvim-dap-df-pane tests..."
	@nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	@find . -name "*.tmp" -delete

# Show help
help:
	@echo "nvim-dap-df-pane Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make test  - Run all tests using plenary"
	@echo "  make clean - Clean generated files"
	@echo "  make help  - Show this help message"