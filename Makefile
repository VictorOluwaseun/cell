.PHONY: build test app run clean
build:
	./scripts/swift.sh build
test:
	./scripts/swift.sh test
app:
	./scripts/build-app.sh
run: app
	open dist/Cell.app
clean:
	./scripts/swift.sh package clean
