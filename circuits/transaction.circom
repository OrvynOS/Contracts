pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/comparators.circom";
include "./merkleproof.circom";

/*
OrvynPay private transaction: 2 input notes, 2 output notes, one asset.

Note:        commitment = Poseidon(amount, publicKey, blinding, asset)
Key:         publicKey  = Poseidon(privateKey)
Signature:   signature  = Poseidon(privateKey, commitment, leafIndex)
Nullifier:   nullifier  = Poseidon(commitment, leafIndex, signature)

Proves:
- each non-zero input note is in the note tree (root) and owned by the prover (privateKey);
- each non-zero output note's owner key is in the shielded key registry (keyRoot), i.e. was
  registered on chain by a wallet holding a Binance Agent ID;
- outputs fit in 248 bits, and sum(inputs) + publicAmount == sum(outputs);
- the two nullifiers differ;
- extDataHash (recipient, relayer, fee, encrypted notes) is bound to the proof.

Public signals, in this order (OrvynShieldedPool._signals):
root, keyRoot, publicAmount, extDataHash, asset, inputNullifier[2], outputCommitment[2]
*/
template Transaction(levels, keyLevels, nIns, nOuts) {
    signal input root;
    signal input keyRoot;
    signal input publicAmount;
    signal input extDataHash;
    signal input asset;

    signal input inputNullifier[nIns];
    signal input inAmount[nIns];
    signal input inPrivateKey[nIns];
    signal input inBlinding[nIns];
    signal input inPathIndices[nIns];
    signal input inPathElements[nIns][levels];

    signal input outputCommitment[nOuts];
    signal input outAmount[nOuts];
    signal input outPubkey[nOuts];
    signal input outBlinding[nOuts];
    signal input outKeyPathIndices[nOuts];
    signal input outKeyPathElements[nOuts][keyLevels];

    component inKeypair[nIns];
    component inCommitmentHasher[nIns];
    component inSignature[nIns];
    component inNullifierHasher[nIns];
    component inTree[nIns];
    component inCheckRoot[nIns];
    var sumIns = 0;

    for (var i = 0; i < nIns; i++) {
        inKeypair[i] = Poseidon(1);
        inKeypair[i].inputs[0] <== inPrivateKey[i];

        inCommitmentHasher[i] = Poseidon(4);
        inCommitmentHasher[i].inputs[0] <== inAmount[i];
        inCommitmentHasher[i].inputs[1] <== inKeypair[i].out;
        inCommitmentHasher[i].inputs[2] <== inBlinding[i];
        inCommitmentHasher[i].inputs[3] <== asset;

        inSignature[i] = Poseidon(3);
        inSignature[i].inputs[0] <== inPrivateKey[i];
        inSignature[i].inputs[1] <== inCommitmentHasher[i].out;
        inSignature[i].inputs[2] <== inPathIndices[i];

        inNullifierHasher[i] = Poseidon(3);
        inNullifierHasher[i].inputs[0] <== inCommitmentHasher[i].out;
        inNullifierHasher[i].inputs[1] <== inPathIndices[i];
        inNullifierHasher[i].inputs[2] <== inSignature[i].out;
        inNullifierHasher[i].out === inputNullifier[i];

        inTree[i] = MerkleProof(levels);
        inTree[i].leaf <== inCommitmentHasher[i].out;
        inTree[i].pathIndices <== inPathIndices[i];
        for (var j = 0; j < levels; j++) {
            inTree[i].pathElements[j] <== inPathElements[i][j];
        }

        // Membership is only checked for non-zero inputs (zero-value dummies need no proof).
        inCheckRoot[i] = ForceEqualIfEnabled();
        inCheckRoot[i].in[0] <== root;
        inCheckRoot[i].in[1] <== inTree[i].root;
        inCheckRoot[i].enabled <== inAmount[i];

        sumIns += inAmount[i];
    }

    component outCommitmentHasher[nOuts];
    component outAmountCheck[nOuts];
    component outKeyTree[nOuts];
    component outCheckKeyRoot[nOuts];
    var sumOuts = 0;

    for (var i = 0; i < nOuts; i++) {
        outCommitmentHasher[i] = Poseidon(4);
        outCommitmentHasher[i].inputs[0] <== outAmount[i];
        outCommitmentHasher[i].inputs[1] <== outPubkey[i];
        outCommitmentHasher[i].inputs[2] <== outBlinding[i];
        outCommitmentHasher[i].inputs[3] <== asset;
        outCommitmentHasher[i].out === outputCommitment[i];

        // No overflow: each output is below 2^248.
        outAmountCheck[i] = Num2Bits(248);
        outAmountCheck[i].in <== outAmount[i];

        // The receiver is a registered (Agent ID verified) shielded key.
        outKeyTree[i] = MerkleProof(keyLevels);
        outKeyTree[i].leaf <== outPubkey[i];
        outKeyTree[i].pathIndices <== outKeyPathIndices[i];
        for (var j = 0; j < keyLevels; j++) {
            outKeyTree[i].pathElements[j] <== outKeyPathElements[i][j];
        }
        outCheckKeyRoot[i] = ForceEqualIfEnabled();
        outCheckKeyRoot[i].in[0] <== keyRoot;
        outCheckKeyRoot[i].in[1] <== outKeyTree[i].root;
        outCheckKeyRoot[i].enabled <== outAmount[i];

        sumOuts += outAmount[i];
    }

    // No note is spent twice in one transaction.
    component sameNullifiers[nIns * (nIns - 1) / 2];
    var index = 0;
    for (var i = 0; i < nIns - 1; i++) {
        for (var j = i + 1; j < nIns; j++) {
            sameNullifiers[index] = IsEqual();
            sameNullifiers[index].in[0] <== inputNullifier[i];
            sameNullifiers[index].in[1] <== inputNullifier[j];
            sameNullifiers[index].out === 0;
            index++;
        }
    }

    // Value is conserved.
    sumIns + publicAmount === sumOuts;

    // Bind the external data to the proof.
    signal extDataSquare <== extDataHash * extDataHash;
    signal keyRootSquare <== keyRoot * keyRoot;
}

// 2^20 notes, 2^16 registered agent keys.
component main {public [root, keyRoot, publicAmount, extDataHash, asset, inputNullifier, outputCommitment]} = Transaction(20, 16, 2, 2);
