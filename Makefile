.venv/.installed:
	python3 -m venv .venv
	.venv/bin/pip install wordfreq
	touch $@

# Rebuild a dictionary DB from its JSONL source.
# Usage: make data/en.db
# Normal dependency tracking means this only reruns when the JSONL is newer
# than the DB.  To force a rebuild: rm data/foo.db && make data/foo.db
data/%.db: data/%.jsonl make-gloss-db | .venv/.installed
	./make-gloss-db $< $@

.PHONY: clean compile

clean:
	rm -rf .venv data/*.db data/*.db-shm data/*.db-wal

compile:
	$(EMACS) --batch -f batch-byte-compile gloss.el
