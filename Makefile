.PHONY: build test app release run clean
build:
	./scripts/swift.sh build
test:
	./scripts/swift.sh test
	python3 -m unittest discover -s Tests/ReleaseTests -v
app:
	./scripts/build-app.sh
release:
	python3 scripts/release.py build --version "$(VERSION)"
run: app
	open dist/Cell.app
clean:
	./scripts/swift.sh package clean
