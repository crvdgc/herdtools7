./_build/default/internal/herd_regression_test.exe \
		-j 8 \
		-herd-path _build/install/default/bin/herd7 \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/AArch64.extra \
		"${@:-test}"

