#!/usr/bin/env bash
# Builds the OrvynPay transaction circuit and exports its Solidity verifier.
#
# Needs circom 2.1.6+ (https://docs.circom.io/getting-started/installation/) and Node; without a
# native circom, CIRCOM="npx circom2" uses the WebAssembly build from npm.
#   cd contracts/circuits && npm install && ./build.sh
#
# DEVELOPMENT SETUP ONLY: the phase-2 contribution below is a single local one. For mainnet run a
# proper multi-party ceremony (several independent contributors and a random beacon) and publish
# the transcript, or anyone holding the toxic waste can forge proofs and drain the pool.
set -euo pipefail
cd "$(dirname "$0")"

PTAU_POWER=${PTAU_POWER:-16}
PTAU="build/ppot_0080_${PTAU_POWER}.ptau"
mkdir -p build

${CIRCOM:-circom} transaction.circom --r1cs --wasm --sym -l node_modules -o build
npx snarkjs r1cs info build/transaction.r1cs

if [ ! -f "$PTAU" ]; then
  # Perpetual Powers of Tau (PSE), phase-1 output after 80 public contributions. (The Hermez
  # mirrors now answer 403.)
  curl -fL -o "$PTAU" "https://pse-trusted-setup-ppot.s3.eu-central-1.amazonaws.com/pot28_0080/ppot_0080_${PTAU_POWER}.ptau"
fi

npx snarkjs groth16 setup build/transaction.r1cs "$PTAU" build/transaction_0000.zkey
npx snarkjs zkey contribute build/transaction_0000.zkey build/transaction.zkey \
  --name="orvyn-dev" -e="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')"
npx snarkjs zkey export verificationkey build/transaction.zkey build/verification_key.json
npx snarkjs zkey export solidityverifier build/transaction.zkey ../src/pay/Groth16Verifier.sol

echo "Built: build/transaction_js/transaction.wasm, build/transaction.zkey, src/pay/Groth16Verifier.sol"
