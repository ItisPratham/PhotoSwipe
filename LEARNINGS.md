# What building this taught me

Things that cost me a day, or would have shipped quietly broken. Kept short on
purpose; the working notes stay out of the repository.

## Models on a phone

**SentencePiece is two different algorithms.** Gemma's model is BPE, and its
per-piece "scores" are merge ranks rather than log probabilities. I wrote a
Unigram tokenizer instead. It produced sensible-looking tokens that were simply
the wrong ones, so search returned mediocre results rather than an error. If
the scores are integers descending by id, it is BPE.

**The right amount of text normalisation was none.** NFC and NFKC both broke
parity against the reference tokenizer, because it treats a decomposed `cafe`
+ ◌́ as its own token sequence. Whitespace is preserved too. Every plausible
default was wrong, and only measuring against the reference showed it.

**Swift compares strings by canonical equivalence.** `"café"` and `"cafe"` +
◌́ are the same dictionary key in Swift, while a tokenizer vocabulary holds
them as different pieces with different ids. My lookups silently conflated
them. Anything that has to match an external byte-exact table should be keyed
by bytes.

**A similarity cutoff belongs to the training objective, not the task.** CLIP
scores a good match around 0.20–0.35; SigLIP, trained with a sigmoid loss,
scores a perfect caption near 0.13 and an unrelated one below zero. Reusing
CLIP's 0.15 threshold discarded every SigLIP result, so the app returned
nothing at all for every query while computing everything correctly.

**Simulator numbers for Core ML can invert the answer.** SigLIP measured 2.5×
slower than MobileCLIP on the Simulator and is faster on an A15. The Mac has
no Neural Engine, so it does not merely round differently — it ranks two
models in the wrong order.

**Float16 conversion looked lossy and was not.** The converted image tower
scored 0.985 cosine against its fp32 reference, which sounds alarming, and it
reproduced the reference's caption ranking exactly. Test the property you
depend on, which here is ordering, not elementwise closeness.

**A better model can still be the wrong model.** SigLIP 2 is faster on device,
permissively licensed, and faithfully converted, and it retrieves worse on my
camera roll than MobileCLIP does. Benchmark standing does not transfer to one
person's photos. The test that decided it was typing "flower" and looking at
the grid.

## iOS

**Give every SwiftData index its own file.** Two containers pointed at the
default store will migrate each other's tables away on open, and the damage
shows up much later as missing data.

**Don't let the root view observe a store that changes on every swipe.** Held
as an observed object it re-renders the whole tab tree; held as a plain
reference, screens observe only what they read.

**A scan that can re-enter itself will deadlock.** One process-wide permit,
taken before the work starts, replaced a set of per-screen guards that each
looked correct alone.

**A free Personal Team does provision App Groups.** The common advice says
otherwise, so the widget was built expecting to fail signing, and it signed.

**A widget streak has to age from the last decision, not the last publish.**
Opening the app republishes the summary, which kept a dead streak alive
indefinitely.

**Never tell a widget about state that has not reached disk.** The review file
write could fail silently and the summary would still publish, advertising
decisions a crash would take back.

**Some ideas only fail on real data.** A percentile-based "Blurry" category was
defensible on paper and useless on an actual library, and a hand-written fast
scroller had to be deleted and replaced with a pinned third-party one.
