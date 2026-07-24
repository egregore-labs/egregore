export function buildEmissaryAnswers(profile, recipient) {
  const portableProfile = JSON.stringify(profile, null, 2);
  return {
    kind: 'build',
    topic: 'Recreate your Egregore and Obsidian second brain',
    claim: 'Running this privately recreates the participant’s chosen capture, resurfacing, and re-entry system without transferring their notes.',
    ask: 'Answer three setup questions, review the proposed file changes, and let your agent build the portable system on your own computer.',
    summary: 'A private configuration packet from the second-brain workshop. It carries preferences and structure, never the participant’s note contents or workshop credentials.',
    prose: 'This is the durable configuration layer from the workshop. Your actual Obsidian vault export stays with you. This packet helps a future agent understand how you chose to work and configure Egregore and Obsidian in tandem.',
    archetype: 'default',
    role_topology: {
      runner_role: 'receiver',
      respondent_role: 'runner',
      subject_role: 'runner',
      beneficiary_role: 'runner',
      author_run_mode: 'run_normally',
    },
    distribution: 'person',
    recipients: [recipient],
    executable_spec: {
      intake: [
        { id: 'vault_path', prompt: 'Where is the Obsidian vault you want to configure?', type: 'text' },
        { id: 'egregore_path', prompt: 'Where is the Egregore workspace that should collaborate with this vault?', type: 'text' },
        {
          id: 'labels',
          prompt: 'Should the agent keep the workshop labels or personalize them with you?',
          type: 'choice',
          options: ['keep Inbox, Now, and Re-entry', 'personalize the labels with me'],
        },
      ],
      action: `1. Inspect the supplied vault_path and egregore_path read-only; report any missing path and stop before writing.\n2. Present the configuration profile below in plain language, including the manual path and privacy defaults; ask for one confirmation before changes.\n3. In vault_path, preserve every existing note. Create only missing Home.md, Inbox.md, Now.md, Re-entry.md, System/Configuration Profile.md, and .second-brain/configuration-profile.json. Use internal wikilinks among these notes and implement capture → context → resurface → re-enter.\n4. Apply the labels answer. If personalization was selected, ask one concrete label question at a time and update links consistently.\n5. In egregore_path/AGENTS.md, preserve existing instructions and add a clearly delimited “Second brain collaboration” section: ask before reading personal notes, never request diagnosis, keep a no-AI path, never put note contents or credentials into emissaries, and treat vault_path as participant-owned.\n6. If egregore_path/egregore.json exists, preserve its fields and add vault_path as a managed repository only after showing the exact JSON change. Do not add API keys or hosted-service fields.\n7. Verify all internal wikilinks resolve, configuration-profile.json parses, and the four-note workflow works without AI. Report each created or changed file and the manual way to use it.\n\nPortable configuration profile:\n${portableProfile}`,
      output: { target: 'receiver_artifact' },
      success_criteria: [
        'the vault contains a linked manual capture, resurfacing, and re-entry workflow',
        'the Egregore instructions preserve consent, privacy, and a no-AI path',
        'no provider key, workshop token, diagnosis, or personal note content is written to the packet',
        'the receiver gets an exact file-change report and link verification result',
      ],
    },
    render_mode: 'default',
  };
}
