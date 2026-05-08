APP_DIR := $(CURDIR)
OVE_DIR ?= $(realpath $(APP_DIR)/../../oveRTOS)
include $(OVE_DIR)/config/make/ove_app.mk
