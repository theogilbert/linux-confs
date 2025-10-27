.PHONY: test clean help

# Default target
all: test

# Run tests using plenary
test:
	@echo "Running nvim-dap-df-pane tests..."
	@nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

format:
	@stylua .

# Show help
help:
	@echo "nvim-dap-df-pane Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make test  - Run all tests using plenary"
	@echo "  make format  - Format lua files"
	@echo "  make help  - Show this help message"
