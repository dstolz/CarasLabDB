classdef (SharedTestFixtures = {LabScratchDb}) TagTests < matlab.unittest.TestCase
%TAGTESTS Tests of the tagging feature of the CarasLabDB MATLAB class.
%
%   results = runtests("tests/matlab")                    % with TAGGUITESTS
%   results = runtests("tests/matlab/TagTests.m")
%   results = runtests("tests/matlab", Tag="NoDatabase")  % no server needed
%
%   The tests tagged "Database" run against a scratch database that the
%   shared fixture LABSCRATCHDB creates and drops; it is opt-in through
%   environment variables (see "help LabScratchDb"). Without them those
%   tests are reported as Incomplete and only the "NoDatabase" ones run --
%   the tag syntax helpers, and checks against RECORDINGCONNECTION that no
%   SQL is sent for invalid input and that defaults pass argument
%   validation (R2024b validates defaults eagerly).
%
%   Each test creates its own rows, with ids and paths made unique by the
%   fixture's counter, so the tests do not depend on each other's data.
%   Tests that change shared vocabulary restore it in a teardown.
%
%   See also LABSCRATCHDB, TAGGUITESTS, RECORDINGCONNECTION.

    properties
        Fx      % the LabScratchDb shared fixture
    end

    methods (TestClassSetup)
        function getFixture(tc)
            tc.Fx = tc.getSharedTestFixtures("LabScratchDb");
        end
    end

    % =====================================================================
    % 0. Connection
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function connectsAsLabRwMember(tc)
            % Section 0: schema version 3, no version warning, person resolved,
            % and the connection is a lab_rw member, not a superuser.
            db = tc.requireDb();
            tc.verifyEqual(db.SchemaVersion, 3);
            tc.verifyEqual(db.SchemaVersion, CarasLabDB.SchemaVersionExpected);
            tc.verifyNotEqual(tc.Fx.ConnectWarningId, "CarasLabDB:schemaVersionMismatch");
            tc.verifyFalse(contains(tc.Fx.ConnectOutput, "Warning"), tc.Fx.ConnectOutput);
            tc.verifyFalse(ismissing(db.CurrentPersonId));
            tc.verifyEqual(db.CurrentPersonId, tc.Fx.PersonId);
            R = db.runQuery("SELECT current_user::text AS who, r.rolsuper, " + ...
                "pg_has_role(current_user, 'lab_rw', 'member') AS in_lab_rw " + ...
                "FROM pg_roles r WHERE r.rolname = current_user");
            tc.verifyEqual(string(R.who), LabScratchDb.RwRole);
            tc.verifyFalse(R.rolsuper);
            tc.verifyTrue(R.in_lab_rw);
        end
    end

    % =====================================================================
    % 1. Static helpers
    % =====================================================================
    methods (Test, TestTags = {'NoDatabase'})
        function normalizeTagCanonicalSpelling(tc)
            % Section 1: case and surrounding spaces only; bare -> tag:.
            tc.verifyEqual(CarasLabDB.normalizeTag(" Stage:Raw "), "stage:raw");
            tc.verifyEqual(CarasLabDB.normalizeTag("Auditory_Cortex"), "tag:auditory_cortex");
            tc.verifyEqual(CarasLabDB.normalizeTag('Topic:V2.1-a'), "topic:v2.1-a");
            in = [" Stage:Raw "; "Auditory_Cortex"; "QC:Pass"];
            tc.verifyEqual(CarasLabDB.normalizeTag(in), ...
                ["stage:raw"; "tag:auditory_cortex"; "qc:pass"], "element by element, shape kept");
            tc.verifyEqual(CarasLabDB.normalizeTag(in'), ...
                ["stage:raw", "tag:auditory_cortex", "qc:pass"]);
            tc.verifyEqual(CarasLabDB.normalizeTag(strings(1, 0)), strings(1, 0));
            % the length limits themselves are legal
            tc.verifyEqual(CarasLabDB.normalizeTag("topic:" + TagTests.as(64)), "topic:" + TagTests.as(64));
            tc.verifyEqual(CarasLabDB.normalizeTag("n" + TagTests.as(31) + ":x"), "n" + TagTests.as(31) + ":x");
        end

        function malformedTagsAreRejected(tc)
            % Section 1: malformed tags raise CarasLabDB:invalidTag, never rewritten.
            for x = TagTests.malformedTags()
                label = "input '" + x + "'";
                tc.verifyError(@() CarasLabDB.normalizeTag(x), "CarasLabDB:invalidTag", label);
                try
                    CarasLabDB.normalizeTag(x);
                catch ME
                    tc.verifySubstring(string(ME.message), "Invalid tag '" + x + "'", label);
                end
            end
            tc.verifyError(@() CarasLabDB.normalizeTag(string(missing)), "CarasLabDB:invalidTag");
            tc.verifyError(@() CarasLabDB.normalizeTag(["stage:raw", "stage:raw data"]), ...
                "CarasLabDB:invalidTag", "one bad element fails the whole array");
        end

        function wildcardOnlyWhenAllowed(tc)
            % Section 1: qc:* rejected by default, accepted with AllowWildcard.
            tc.verifyError(@() CarasLabDB.normalizeTag("qc:*"), "CarasLabDB:invalidTag");
            tc.verifyError(@() CarasLabDB.parseTag("qc:*"), "CarasLabDB:invalidTag");
            tc.verifyEqual(CarasLabDB.normalizeTag("qc:*", AllowWildcard=true), "qc:*");
            tc.verifyEqual(CarasLabDB.normalizeTag(" QC:* ", AllowWildcard=true), "qc:*");
            tc.verifyError(@() CarasLabDB.normalizeTag("qc:p*", AllowWildcard=true), "CarasLabDB:invalidTag");
            tc.verifyError(@() CarasLabDB.normalizeTag("q*:x", AllowWildcard=true), "CarasLabDB:invalidTag");
        end

        function parseTagSplitsAtFirstColon(tc)
            % Section 1: parseTag returns the namespace and value.
            [ns, v] = CarasLabDB.parseTag(" Stage:Raw ");
            tc.verifyEqual([ns, v], ["stage", "raw"]);
            [ns, v] = CarasLabDB.parseTag("Auditory_Cortex");
            tc.verifyEqual([ns, v], ["tag", "auditory_cortex"]);
            [ns, v] = CarasLabDB.parseTag("topic:v2.1");
            tc.verifyEqual([ns, v], ["topic", "v2.1"]);
            tc.verifyError(@() CarasLabDB.parseTag("a:b:c"), "CarasLabDB:invalidTag");
        end

        function displayTagStripsOnlyTheBarePrefix(tc)
            % Section 1: displayTag.
            tc.verifyEqual(CarasLabDB.displayTag("tag:auditory_cortex"), "auditory_cortex");
            tc.verifyEqual(CarasLabDB.displayTag("stage:raw"), "stage:raw");
            tc.verifyEqual(CarasLabDB.displayTag(["tag:a"; "topic:b"; "tagx:c"]), ["a"; "topic:b"; "tagx:c"]);
        end
    end

    methods (Test, TestTags = {'Database'})
        function normalizeTagAgreesWithDatabase(tc)
            % Section 1: every MATLAB result equals lab.fn_canonical_tag; every
            % input MATLAB rejects, the database rejects too.
            tc.requireDb();
            good = [" Stage:Raw ", "Auditory_Cortex", "QC:Pass", "  topic:V2.1-a", ...
                    "TAG:Mixed_Case", "topic:" + TagTests.as(64), "n" + TagTests.as(31) + ":x"];
            for x = good
                canon = string(tc.Fx.scalar("SELECT lab.fn_canonical_tag(" + LabScratchDb.quote(x) + ") AS t"));
                tc.verifyEqual(CarasLabDB.normalizeTag(x), canon, "input '" + x + "'");
                [ns, v] = CarasLabDB.parseTag(x);
                tc.verifyEqual(ns + ":" + v, canon);
            end
            for x = [TagTests.malformedTags(), "qc:*"]
                % The database's canonical form is not a valid tag either:
                % inserting it into lab.tag fails (in a rolled-back transaction).
                tc.verifyTrue(tc.databaseRejectsTag(x), "database accepted '" + x + "'");
            end
        end
    end

    % =====================================================================
    % 2. Vocabulary
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function seededNamespacesAndFilters(tc)
            % Section 2: getTagNamespaces, its filters, and readable applies_to.
            db = tc.requireDb();
            NS = db.getTagNamespaces();
            names = string(NS.namespace);
            tc.verifyClass(NS.applies_to, "string", "applies_to is text, not an array object");
            % name, mutability, cardinality, open_vocabulary, applies_to
            seeded = {
                "cohort",    "immutable", "single", true,  "subject,session"
                "condition", "immutable", "single", true,  "subject,session,event"
                "qc",        "mutable",   "single", false, "artifact,event,session"
                "stage",     "mutable",   "single", false, "artifact"
                "tag",       "mutable",   "multi",  true,  "event,artifact,subject,session,project"
                "topic",     "mutable",   "multi",  true,  "event,artifact,subject,session,project"};
            for i = 1:size(seeded, 1)
                r = find(names == seeded{i, 1});
                tc.assertNumElements(r, 1, seeded{i, 1});
                tc.verifyEqual(string(NS.mutability(r)), seeded{i, 2}, seeded{i, 1});
                tc.verifyEqual(string(NS.cardinality(r)), seeded{i, 3}, seeded{i, 1});
                tc.verifyEqual(logical(NS.open_vocabulary(r)), seeded{i, 4}, seeded{i, 1});
                tc.verifyEqual(NS.applies_to(r), seeded{i, 5}, seeded{i, 1});
            end
            others = setdiff(names, string(seeded(:, 1)));
            tc.verifyTrue(all(startsWith(others, "mt_")), ...
                "namespaces other than the seeded six and the tests' mt_*: " + strjoin(others, ", "));

            A = db.getTagNamespaces(AppliesTo="artifact");
            want = names(contains("," + NS.applies_to + ",", ",artifact,"));
            tc.verifyEqual(sort(string(A.namespace)), sort(want));
            tc.verifyTrue(all(ismember(["qc", "stage", "tag", "topic"], string(A.namespace))));
            tc.verifyFalse(any(ismember(["cohort", "condition"], string(A.namespace))));
            S = db.getTagNamespaces(Namespace="stage");
            tc.verifyEqual(string(S.namespace), "stage");
            B = db.getTagNamespaces(Namespace="cohort", AppliesTo="artifact");
            tc.verifyEqual(height(B), 0);
            tc.verifyError(@() db.getTagNamespaces(AppliesTo="foo"), "CarasLabDB:unknownEntityKind");
        end

        function seededStageAndQcValues(tc)
            % Section 2: getTags returns the seeded values, ordered by namespace, value.
            db = tc.requireDb();
            T = db.getTags(Namespace="stage");
            tc.verifyEqual(string(T.value)', ["analyzed", "curated", "preprocessed", "raw", "sorted"]);
            tc.verifyEqual(string(T.tag)', "stage:" + ["analyzed", "curated", "preprocessed", "raw", "sorted"]);
            tc.verifyTrue(all(isnat(T.retired_at)));
            Q = db.getTags(Namespace="qc");
            tc.verifyEqual(string(Q.value)', ["fail", "pass", "pending"]);
            All = db.getTags();
            seeded = ismember(string(All.namespace), ["qc", "stage"]);
            tc.verifyEqual(string(All.tag(seeded))', ["qc:" + ["fail", "pass", "pending"], ...
                "stage:" + ["analyzed", "curated", "preprocessed", "raw", "sorted"]], ...
                "getTags() is ordered by namespace, value");
        end

        function addTagNamespaceOpenAndClosed(tc)
            % Section 2: addTagNamespace, applies_to given as a string array.
            db = tc.requireDb();
            ns = db.addTagNamespace(Namespace="mt_open_multi", Mutability="mutable", ...
                Cardinality="multi", AppliesTo=["event", "artifact"], Description="open, multi");
            tc.verifyEqual(ns, "mt_open_multi");
            R = db.getTagNamespaces(Namespace="mt_open_multi");
            tc.verifyEqual([string(R.mutability), string(R.cardinality), R.applies_to], ...
                ["mutable", "multi", "event,artifact"]);
            tc.verifyTrue(logical(R.open_vocabulary));
            tc.verifyEqual(string(R.created_by), db.CurrentPersonId);

            db.addTagNamespace(Namespace="mt_closed_single", Mutability="immutable", ...
                Cardinality="single", AppliesTo=["session", "subject", "session"], OpenVocabulary=false);
            R = db.getTagNamespaces(Namespace="mt_closed_single");
            tc.verifyEqual([string(R.mutability), string(R.cardinality), R.applies_to], ...
                ["immutable", "single", "subject,session"], "duplicates dropped, fixed order");
            tc.verifyFalse(logical(R.open_vocabulary));

            tc.verifyError(@() db.addTagNamespace(Namespace="Probe_Site", Mutability="mutable", ...
                Cardinality="multi", AppliesTo="event"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.addTagNamespace(Namespace="mt_bad_kind", Mutability="mutable", ...
                Cardinality="multi", AppliesTo=["event", "foo"]), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.addTagNamespace(Namespace="mt_bad_mut", Mutability="sometimes", ...
                Cardinality="multi", AppliesTo="event"), "MATLAB:validators:mustBeMember");
            tc.verifyError(@() db.addTagNamespace(Namespace="mt_open_multi", Mutability="mutable", ...
                Cardinality="multi", AppliesTo="event"), ?MException, "duplicate namespace");
            tc.verifyEqual(height(db.getTagNamespaces(Namespace="mt_bad_kind")), 0);
        end

        function registerTagInClosedNamespace(tc)
            % Section 2: registerTag works in a closed namespace; addTag of an
            % unregistered value fails, listing the valid ones.
            db = tc.requireDb();
            db.addTagNamespace(Namespace="mt_closed_reg", Mutability="mutable", ...
                Cardinality="single", AppliesTo="subject", OpenVocabulary=false);
            t = db.registerTag(" MT_Closed_Reg:Alpha ", Description="first value");
            tc.verifyEqual(t, "mt_closed_reg:alpha");
            T = db.getTags(Namespace="mt_closed_reg");
            tc.verifyEqual(string(T.value), "alpha");
            tc.verifyEqual(string(T.description), "first value");
            tc.verifyEqual(string(T.created_by), db.CurrentPersonId);
            db.registerTag("mt_closed_reg:alpha", Description="ignored");
            T = db.getTags(Namespace="mt_closed_reg");
            tc.verifyEqual(string(T.description), "first value", "re-registering changes nothing");

            w = tc.Fx.makeWorld("reg", 0);
            err = tc.errorOf(@() db.addTag("subject", w.SubjectId, "mt_closed_reg:beta"));
            tc.verifySubstring(string(err.message), "closed vocabulary");
            tc.verifySubstring(string(err.message), "(its values: alpha)");
            err = tc.errorOf(@() db.setTag("subject", w.SubjectId, "mt_closed_reg:beta"));
            tc.verifySubstring(string(err.message), "closed vocabulary");
            tc.verifyEqual(height(db.getEntityTags("subject", w.SubjectId, History=true)), 0);
            tc.verifyEqual(height(db.getTags(Namespace="mt_closed_reg")), 1, "beta was not registered");

            [~, changed] = db.setTag("subject", w.SubjectId, "mt_closed_reg:alpha");
            tc.verifyTrue(changed);
            tc.verifyError(@() db.registerTag("mt_nope:x"), "CarasLabDB:tagNamespaceNotFound");
            tc.verifyError(@() db.registerTag("mt_closed_reg:Bad Value"), "CarasLabDB:invalidTag");
        end

        function updateTagNamespaceFreezesOnFirstUse(tc)
            % Section 2: policy editable before use, frozen after; row_history.
            db = tc.requireDb();
            ns = "mt_upd";
            db.addTagNamespace(Namespace=ns, Mutability="mutable", Cardinality="multi", AppliesTo="event");
            h0 = tc.Fx.rowHistoryCount("tag_namespace", "namespace", ns);

            db.updateTagNamespace(ns, Mutability="immutable", Cardinality="single", ...
                AppliesTo=["event", "artifact", "subject"]);
            tc.verifyNamespace(ns, "immutable", "single", "event,artifact,subject");
            db.updateTagNamespace(ns, AppliesTo=["event", "artifact"]);     % shrink, before use
            tc.verifyNamespace(ns, "immutable", "single", "event,artifact");
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag_namespace", "namespace", ns) - h0, 2);

            w = tc.Fx.makeWorld("upd", 0);
            db.addTag("event", w.EventId, ns + ":v1");
            h1 = tc.Fx.rowHistoryCount("tag_namespace", "namespace", ns);
            frozen = "tag namespace " + ns + " is in use, so its policy is frozen";
            err = tc.errorOf(@() db.updateTagNamespace(ns, Mutability="mutable"));
            tc.verifySubstring(string(err.message), frozen);
            err = tc.errorOf(@() db.updateTagNamespace(ns, Cardinality="multi"));
            tc.verifySubstring(string(err.message), frozen);
            err = tc.errorOf(@() db.updateTagNamespace(ns, AppliesTo="event"));
            tc.verifySubstring(string(err.message), frozen);
            tc.verifyNamespace(ns, "immutable", "single", "event,artifact");

            db.updateTagNamespace(ns, AppliesTo=["event", "artifact", "session"]);   % grow
            db.updateTagNamespace(ns, Description="edited after use");
            db.updateTagNamespace(ns, OpenVocabulary=false);
            R = db.getTagNamespaces(Namespace=ns);
            tc.verifyEqual(R.applies_to, "event,artifact,session");
            tc.verifyEqual(string(R.description), "edited after use");
            tc.verifyFalse(logical(R.open_vocabulary));
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag_namespace", "namespace", ns) - h1, 3, ...
                "one row_history row per UPDATE that succeeded, none for refused ones");
            db.updateTagNamespace(ns, Description="edited after use");      % changes nothing
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag_namespace", "namespace", ns) - h1, 3);
            H = db.runQuery("SELECT changed_by, operation FROM lab.row_history " + ...
                "WHERE table_name = 'tag_namespace' AND row_key ->> 'namespace' = '" + ns + "' " + ...
                "ORDER BY history_id DESC LIMIT 1");
            tc.verifyEqual([string(H.changed_by), string(H.operation)], [LabScratchDb.RwRole, "UPDATE"]);

            % "Even if since removed -- the log still holds it."
            ns2 = "mt_upd_removed";
            db.addTagNamespace(Namespace=ns2, Mutability="mutable", Cardinality="multi", AppliesTo="event");
            db.addTag("event", w.EventId, ns2 + ":v");
            db.removeTag("event", w.EventId, ns2 + ":v");
            err = tc.errorOf(@() db.updateTagNamespace(ns2, Cardinality="single"));
            tc.verifySubstring(string(err.message), "is in use, so its policy is frozen");

            tc.verifyError(@() db.updateTagNamespace("mt_no_such", Description="x"), ...
                "CarasLabDB:tagNamespaceNotFound");
            tc.verifyWarning(@() db.updateTagNamespace(ns), "CarasLabDB:nothingToUpdate");
            tc.verifyError(@() db.updateTagNamespace(ns, Mutability="sometimes"), "CarasLabDB:invalidValue");
        end

        function reservedTagNamespaceOnlyDescription(tc)
            % Section 2: on the reserved 'tag' namespace only the description changes.
            db = tc.requireDb();
            orig = string(db.getTagNamespaces(Namespace="tag").description);
            tc.addTeardown(@() db.updateTagNamespace("tag", Description=orig));
            h0 = tc.Fx.rowHistoryCount("tag_namespace", "namespace", "tag");
            db.updateTagNamespace("tag", Description="edited by TagTests");
            tc.verifyEqual(string(db.getTagNamespaces(Namespace="tag").description), "edited by TagTests");
            reserved = "tag namespace tag is reserved for bare tags";
            err = tc.errorOf(@() db.updateTagNamespace("tag", Mutability="immutable"));
            tc.verifySubstring(string(err.message), reserved);
            err = tc.errorOf(@() db.updateTagNamespace("tag", Cardinality="single"));
            tc.verifySubstring(string(err.message), reserved);
            err = tc.errorOf(@() db.updateTagNamespace("tag", OpenVocabulary=false));
            tc.verifySubstring(string(err.message), reserved);
            err = tc.errorOf(@() db.updateTagNamespace("tag", AppliesTo=["event", "artifact"]));
            tc.verifySubstring(string(err.message), reserved);
            tc.verifyNamespace("tag", "mutable", "multi", "event,artifact,subject,session,project");
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag_namespace", "namespace", "tag") - h0, 1);
        end

        function retireTagStopsNewAssignmentsOnly(tc)
            % Section 2: retireTag / Unretire, and row_history for lab.tag.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("retire", 2);
            [a1, a2] = deal(w.ArtifactIds(1), w.ArtifactIds(2));
            db.setTag("artifact", a1, "stage:curated");
            tc.addTeardown(@() db.retireTag("stage:curated", Unretire=true));
            h0 = tc.Fx.rowHistoryCount("tag", "tag", "stage:curated");

            db.retireTag(" Stage:Curated ");
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag", "tag", "stage:curated") - h0, 1);
            tc.verifyFalse(ismember("curated", string(db.getTags(Namespace="stage").value)));
            T = db.getTags(Namespace="stage", IncludeRetired=true);
            tc.verifyTrue(ismember("curated", string(T.value)));
            tc.verifyFalse(isnat(T.retired_at(string(T.value) == "curated")));

            err = tc.errorOf(@() db.addTag("artifact", a2, "stage:curated"));
            tc.verifySubstring(string(err.message), "was retired");
            err = tc.errorOf(@() db.setTag("artifact", a2, "stage:curated"));
            tc.verifySubstring(string(err.message), "was retired");
            tc.verifyEqual(tc.currentTags("artifact", a2), strings(0, 1));
            tc.verifyEqual(tc.currentTags("artifact", a1), "stage:curated", "the carrier keeps it");

            db.retireTag("stage:curated");     % already retired: nothing changes
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag", "tag", "stage:curated") - h0, 1);
            tc.verifyWarning(@() db.registerTag("stage:curated"), "CarasLabDB:tagRetired");
            db.removeTag("artifact", a1, "stage:curated");   % a remove is still allowed
            tc.verifyEqual(tc.currentTags("artifact", a1), strings(0, 1));

            db.retireTag("stage:curated", Unretire=true);
            tc.verifyEqual(tc.Fx.rowHistoryCount("tag", "tag", "stage:curated") - h0, 2);
            tc.verifyTrue(ismember("curated", string(db.getTags(Namespace="stage").value)));
            db.addTag("artifact", a2, "stage:curated");
            tc.verifyEqual(tc.currentTags("artifact", a2), "stage:curated");
            tc.verifyError(@() db.retireTag("stage:no_such"), "CarasLabDB:tagNotFound");
        end
    end

    % =====================================================================
    % 3. Assigning tags
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function addAndRemoveOnEveryKind(tc)
            % Section 3: addTag / removeTag with several tags on all five kinds,
            % getEntityTags current and History=true.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("kinds", 1);
            ents = {"event", w.EventId; "artifact", w.ArtifactIds(1); "subject", w.SubjectId
                    "session", w.SessionId; "project", w.ProjectId};
            for k = 1:size(ents, 1)
                [kind, id] = ents{k, :};
                ids = db.addTag(kind, id, ["topic:alpha", "Topic:Beta", "pilot", "topic:alpha"]);
                tc.verifySize(ids, [1 3], kind + ": the repeated tag is written once");
                tc.verifyEqual(tc.currentTags(kind, id), ["tag:pilot"; "topic:alpha"; "topic:beta"], kind);
                T = db.getEntityTags(kind, id);
                tc.verifyEqual(string(T.display_tag), CarasLabDB.displayTag(string(T.tag)), kind);
                tc.verifyEqual(string(T.display_tag(string(T.tag) == "tag:pilot")), "pilot", kind);

                rids = db.removeTag(kind, id, ["topic:alpha", "PILOT"]);
                tc.verifySize(rids, [1 2], kind);
                tc.verifyEqual(tc.currentTags(kind, id), "topic:beta", kind);

                H = db.getEntityTags(kind, id, History=true);
                tc.verifyEqual(string(H.op)', ["add", "add", "add", "remove", "remove"], kind);
                tc.verifyEqual(string(H.tag)', ["topic:alpha", "topic:beta", "tag:pilot", ...
                    "topic:alpha", "tag:pilot"], kind);
                tc.verifyEqual(H.assignment_id', [ids, rids], kind);
                tc.verifyTrue(all(string(H.applied_by) == db.CurrentPersonId), kind);
            end
        end

        function bareTagAndMixedCaseDuplicate(tc)
            % Section 3: a bare tag is stored as tag:x and shown bare; the same
            % tag in other case is a duplicate add.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("bare", 1);
            aid = w.ArtifactIds(1);
            db.addTag("artifact", aid, "auditory_cortex");
            T = db.getEntityTags("artifact", aid);
            tc.verifyEqual([string(T.tag), string(T.display_tag)], ["tag:auditory_cortex", "auditory_cortex"]);
            err = tc.errorOf(@() db.addTag("artifact", aid, "TAG:Auditory_Cortex"));
            tc.verifySubstring(string(err.message), "already has tag tag:auditory_cortex");
            tc.verifyEqual(height(db.getEntityTags("artifact", aid, History=true)), 1);
            V = db.getTags(Namespace="tag");
            tc.verifyEqual(nnz(string(V.value) == "auditory_cortex"), 1);
        end

        function setTagReplacesInSingleValuedNamespace(tc)
            % Section 3: setTag replace, idempotence, and refusal on multi.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("set", 1);
            aid = w.ArtifactIds(1);
            [id1, c1] = db.setTag("artifact", aid, "stage:raw");
            [id2, c2] = db.setTag("artifact", aid, "Stage:Preprocessed");
            tc.verifyTrue(c1);
            tc.verifyTrue(c2);
            H = db.getEntityTags("artifact", aid, History=true);
            tc.verifyEqual(string(H.op)', ["add", "remove", "add"]);
            tc.verifyEqual(string(H.tag)', ["stage:raw", "stage:raw", "stage:preprocessed"]);
            tc.verifyEqual(string(H.note(2)), "replaced by stage:preprocessed");
            tc.verifyEqual(H.assignment_id([1 3])', [id1, id2]);
            C = db.getEntityTags("artifact", aid);
            tc.verifyEqual(string(C.tag(string(C.namespace) == "stage")), "stage:preprocessed");
            tc.verifyEqual(C.assignment_id, id2);

            [id3, c3] = db.setTag("artifact", aid, "stage:preprocessed");
            tc.verifyFalse(c3);
            tc.verifyEqual(id3, id2, "returns the existing assignment");
            tc.verifyEqual(height(db.getEntityTags("artifact", aid, History=true)), 3, "no new log row");

            tc.verifyError(@() db.setTag("artifact", aid, "topic:x"), "CarasLabDB:notSingleValued");
            tc.verifyError(@() db.setTag("artifact", aid, "pilot"), "CarasLabDB:notSingleValued");
            tc.verifyError(@() db.setTag("artifact", aid, "mt_nope:x"), "CarasLabDB:tagNamespaceNotFound");
            tc.verifyEqual(height(db.getEntityTags("artifact", aid, History=true)), 3);
        end

        function addTagReplacesButRawInsertIsRefused(tc)
            % Section 3: addTag in a mutable single-valued namespace replaces
            % (lab.fn_tag); a direct INSERT is refused with a HINT.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("replace", 1);
            aid = w.ArtifactIds(1);
            db.setTag("artifact", aid, "stage:raw");
            id = db.addTag("artifact", aid, "stage:sorted");
            tc.verifyEqual(tc.currentTags("artifact", aid), "stage:sorted");
            H = db.getEntityTags("artifact", aid, History=true);
            tc.verifyEqual(string(H.op)', ["add", "remove", "add"]);
            tc.verifyEqual(string(H.note(2)), "replaced by stage:sorted");
            tc.verifyEqual(H.assignment_id(end), id);

            err = tc.errorOf(@() db.runCommand("INSERT INTO lab.tag_assignment " + ...
                "(entity_kind, artifact_id, tag, op) VALUES ('artifact', '" + aid + "', 'stage:raw', 'add')"));
            tc.verifySubstring(string(err.message), "already has stage:sorted, and namespace stage allows one current tag");
            tc.verifySubstring(string(err.message), "HINT:  Use lab.fn_tag");
            tc.verifyEqual(height(db.getEntityTags("artifact", aid, History=true)), 3);
        end

        function immutableNamespaceIsPermanent(tc)
            % Section 3: cohort (immutable, single) can be set once, never changed.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("cohort", 0);
            sid = w.SubjectId;
            [~, changed] = db.setTag("subject", sid, "cohort:a");
            tc.verifyTrue(changed);
            err = tc.errorOf(@() db.removeTag("subject", sid, "cohort:a"));
            tc.verifySubstring(string(err.message), "tag namespace cohort is immutable");
            err = tc.errorOf(@() db.setTag("subject", sid, "cohort:b"));
            tc.verifySubstring(string(err.message), "already has cohort:a, and namespace cohort is immutable and single-valued");
            err = tc.errorOf(@() db.addTag("subject", sid, "cohort:b"));
            tc.verifySubstring(string(err.message), "is immutable and single-valued");
            [~, changed] = db.setTag("subject", sid, "cohort:a");
            tc.verifyFalse(changed, "setting the same value again is a no-op");
            tc.verifyEqual(tc.currentTags("subject", sid), "cohort:a");
            tc.verifyEqual(height(db.getEntityTags("subject", sid, History=true)), 1);
        end

        function appliesToIsEnforced(tc)
            % Section 3: a tag on a kind outside its namespace's applies_to fails.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("applies", 0);
            err = tc.errorOf(@() db.addTag("event", w.EventId, "stage:raw"));
            tc.verifySubstring(string(err.message), "tags of namespace stage apply to artifact only, not to event");
            err = tc.errorOf(@() db.setTag("event", w.EventId, "stage:raw"));
            tc.verifySubstring(string(err.message), "apply to artifact only, not to event");
            err = tc.errorOf(@() db.addTag("project", w.ProjectId, "qc:pass"));
            tc.verifySubstring(string(err.message), "apply to artifact, event, session only, not to project");
            tc.verifyEqual(height(db.getEntityTags("event", w.EventId, History=true)), 0);
        end

        function removingAbsentTagFailsAndMultiTagWritesAreAtomic(tc)
            % Section 3: remove of a tag not present fails; several tags are all
            % or none.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("absent", 1);
            aid = w.ArtifactIds(1);
            err = tc.errorOf(@() db.removeTag("artifact", aid, "stage:raw"));
            tc.verifySubstring(string(err.message), "does not currently have tag stage:raw");
            db.addTag("artifact", aid, "topic:gone");
            db.removeTag("artifact", aid, "topic:gone");
            err = tc.errorOf(@() db.removeTag("artifact", aid, "topic:gone"));
            tc.verifySubstring(string(err.message), "does not currently have tag topic:gone");

            db.addTag("artifact", aid, "topic:keep");
            n0 = height(db.getEntityTags("artifact", aid, History=true));
            tc.errorOf(@() db.removeTag("artifact", aid, ["topic:keep", "stage:raw"]));
            tc.verifyEqual(tc.currentTags("artifact", aid), "topic:keep", "the first remove was rolled back");
            tc.errorOf(@() db.addTag("artifact", aid, ["topic:atomic_new", "stage:not_a_stage"]));
            tc.verifyEqual(tc.currentTags("artifact", aid), "topic:keep", "the first add was rolled back");
            tc.verifyFalse(ismember("atomic_new", string(db.getTags(Namespace="topic").value)), ...
                "its auto-registration was rolled back too");
            tc.verifyEqual(height(db.getEntityTags("artifact", aid, History=true)), n0);
            tc.verifyEqual(string(db.Connection.AutoCommit), "on");
        end

        function upperCaseUuidsResolve(tc)
            % Section 3: uuid ids given in upper case resolve.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("upper", 1);
            aid = w.ArtifactIds(1);
            db.addTag("artifact", upper(aid), "topic:upper");
            tc.verifyEqual(tc.currentTags("artifact", aid), "topic:upper");
            tc.verifyEqual(tc.currentTags("artifact", upper(aid)), "topic:upper");
            [~, c1] = db.setTag("artifact", upper(aid), "stage:raw");
            [~, c2] = db.setTag("artifact", upper(aid), "stage:raw");
            tc.verifyEqual([c1, c2], [true, false]);
            db.removeTag("artifact", upper(aid), "topic:upper");
            tc.verifyEqual(tc.currentTags("artifact", aid), "stage:raw");
            for e = {"event", w.EventId; "session", w.SessionId; "project", w.ProjectId}'
                db.addTag(e{1}, upper(e{2}), "topic:upper");
                tc.verifyEqual(tc.currentTags(e{1}, e{2}), "topic:upper", e{1});
            end
            ids = db.findByTags("artifact", Tags="stage:raw");
            tc.verifyTrue(ismember(aid, ids), "findByTags returns the canonical lower-case id");
        end
    end

    methods (Test, TestTags = {'NoDatabase'})
        function unknownKindFailsBeforeAnySql(tc)
            % Section 3: an unknown kind errors in MATLAB before any SQL runs.
            [db, conn] = TagTests.recordingDb();
            calls = {
                @() db.addTag("foo", "x", "topic:a")
                @() db.removeTag("foo", "x", "topic:a")
                @() db.setTag("foo", "x", "stage:raw")
                @() db.getEntityTags("foo", "x")
                @() db.findByTags("foo")
                @() db.getTagNamespaces(AppliesTo="foo")
                @() db.addTag("Artifact", "x", "topic:a")
                @() db.addTag("event; DROP TABLE lab.tag; --", "x", "topic:a")
                @() db.updateTagNamespace("topic", AppliesTo=["event", "foo"])
                @() db.addTagNamespace(Namespace="mt_a", Mutability="mutable", ...
                        Cardinality="multi", AppliesTo="foo")
                @() db.addTag("artifact", "x", "topic:o'brien")
                @() db.getArtifacts(Tags="x');DROP TABLE lab.tag;--")
                @() db.findByTags("artifact", NotTags="topic:o'brien")};
            for i = 1:numel(calls)
                tc.verifyError(calls{i}, ?MException, func2str(calls{i}));
            end
            tc.verifyEmpty(conn.Log, "SQL was sent: " + strjoin(conn.Log, newline));
        end

        function callerTextStaysInsideLiterals(tc)
            % Section 3: no identifier is built from caller text. Hostile ids,
            % notes and names reach the SQL only inside quoted literals.
            [db, conn] = TagTests.recordingDb();
            bad = "x'); DROP TABLE lab.tag; --";
            calls = {
                @() db.addTag("artifact", bad, "topic:a", Note=bad)
                @() db.removeTag("subject", bad, ["topic:a", "topic:b"], Note=bad)
                @() db.setTag("session", bad, "qc:pass", Note=bad)
                @() db.getEntityTags("event", bad)
                @() db.getEntityTags("project", bad, History=true)
                @() db.getTagNamespaces(Namespace=bad)
                @() db.getTags(Namespace=bad)
                @() db.updateTagNamespace(bad, Description=bad)
                @() db.registerTag("topic:a", Description=bad)
                @() db.addTagNamespace(Namespace="mt_a", Mutability="mutable", ...
                        Cardinality="multi", AppliesTo="event", Description=bad)
                @() db.getArtifacts(SubjectId=bad, Tags="topic:a")
                @() db.supersedeArtifact(bad)
                @() db.supersedeEvent(bad, Notes=bad)};
            for i = 1:numel(calls)
                try
                    calls{i}();
                catch
                    % The fake connection returns empty results; only the SQL matters.
                end
            end
            tc.assertNotEmpty(conn.Log);
            tc.verifyTrue(any(contains(conn.Log, "DROP TABLE lab.tag")), "the hostile text was sent");
            for sql = conn.Log'
                outside = regexprep(sql, "E?'(?:[^']|'')*'", "''");
                tc.verifyFalse(contains(outside, "DROP", IgnoreCase=true), sql);
            end
        end
    end

    % =====================================================================
    % 4. Filters
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function artifactFiltersAgreeWithDatabase(tc)
            % Section 4: getArtifacts / findByTags against lab.fn_find_by_tags.
            tc.requireDb();
            f = tc.filterWorld();
            A = f.A;
            scope = A;
            tc.checkFilter("artifact", struct(Tags="stage:raw"), A([1 2 4]), scope, "Tags=stage:raw");
            tc.checkFilter("artifact", struct(Tags=["stage:raw", "topic:x"]), A([1 4]), scope, "AND");
            tc.checkFilter("artifact", struct(AnyTags=["qc:pass", "qc:fail"]), A([1 2 4 6]), scope, "AnyTags");
            tc.checkFilter("artifact", struct(NotTags="qc:fail"), A([1 3 5 6]), scope, "NotTags");
            tc.checkFilter("artifact", struct(NotTags="qc:*"), A([3 5]), scope, "never QC'd");
            tc.checkFilter("artifact", struct(Tags="qc:*"), A([1 2 4 6]), scope, "Tags=qc:*");
            tc.checkFilter("artifact", struct(Tags="pilot"), A([1 6]), scope, "bare token");
            tc.checkFilter("artifact", struct(Tags=[" Stage:RAW ", "TOPIC:X  "]), A([1 4]), scope, ...
                "mixed case and whitespace");
            tc.checkFilter("artifact", struct(Tags="stage:raw", SubjectId=f.S(2)), A(4), scope, ...
                "Tags + SubjectId");
            tc.checkFilter("artifact", struct(Tags="stage:raw", AnyTags=["topic:x", "topic:y"], ...
                NotTags="qc:fail"), A(1), scope, "all three lists");

            % Superseded rows: the correction carries the tags; history keeps both.
            a6new = tc.Fx.Db.supersedeArtifact(A(6), Overrides=struct("format", "dat2"));
            scope = [A, a6new];
            tc.checkFilter("artifact", struct(Tags="pilot"), [A(1), a6new], scope, "active only");
            tc.checkFilter("artifact", struct(Tags="pilot", ActiveOnly=false), [A(1), A(6), a6new], ...
                scope, "ActiveOnly=false");
            tc.checkFilter("artifact", struct(NotTags="qc:*", ActiveOnly=false), A([3 5]), scope, ...
                "ActiveOnly=false, NotTags");

            % Blank and missing tokens are no constraint.
            db = tc.Fx.Db;
            allIds = sort(LabScratchDb.column(db.getArtifacts(), "artifact_id"));
            tc.verifyEqual(sort(LabScratchDb.column(db.getArtifacts(Tags=["", "  "]), "artifact_id")), allIds);
            tc.verifyEqual(sort(LabScratchDb.column(db.getArtifacts(AnyTags=string(missing)), ...
                "artifact_id")), allIds);
            tc.verifyEqual(sort(tc.Fx.findByTagsSql("artifact", ["", " "])), allIds);
        end

        function otherKindFiltersAgreeWithDatabase(tc)
            % Section 4: a representative subset on events, subjects, sessions,
            % projects.
            tc.requireDb();
            f = tc.filterWorld();
            E = f.E;
            tc.checkFilter("event", struct(Tags="qc:pass"), E(1), E, "events Tags");
            tc.checkFilter("event", struct(NotTags="qc:*"), E([3 4]), E, "events never QC'd");
            tc.checkFilter("event", struct(AnyTags=["pilot", "qc:fail"]), E([2 3]), E, "events AnyTags");
            tc.checkFilter("event", struct(Tags="PILOT"), E(3), E, "events bare, upper case");
            tc.checkFilter("event", struct(Tags="qc:*", SubjectId=f.S(1)), E([1 2]), E, "events + SubjectId");
            tc.checkFilter("subject", struct(Tags="cohort:a"), f.S(1), f.S, "subjects");
            tc.checkFilter("subject", struct(Tags="cohort:*"), f.S, f.S, "subjects wildcard");
            tc.checkFilter("subject", struct(NotTags="topic:x"), f.S(2), f.S, "subjects NotTags");
            tc.checkFilter("subject", struct(AnyTags=["topic:x", "cohort:b"]), f.S, f.S, "subjects AnyTags");
            tc.checkFilter("session", struct(Tags="qc:pass"), f.SS(1), f.SS, "sessions");
            tc.checkFilter("session", struct(NotTags="qc:*"), f.SS(2), f.SS, "sessions never QC'd");
            tc.checkFilter("session", struct(Tags="qc:pass", SubjectId=f.S(1)), f.SS(1), f.SS, ...
                "sessions + SubjectId");
            tc.checkFilter("project", struct(Tags="topic:x"), f.P(1), f.P, "projects");
            tc.checkFilter("project", struct(AnyTags=["pilot", "topic:x"]), f.P, f.P, "projects AnyTags");
            tc.checkFilter("project", struct(NotTags="pilot"), f.P(1), f.P, "projects NotTags");
            tc.checkFilter("project", struct(Tags="Pilot"), f.P(2), f.P, "projects bare");
        end

        function quoteInTokenIsRejectedNotInjected(tc)
            % Section 4: a token with a single quote is refused by validation.
            db = tc.requireDb();
            q = "topic:o'brien";
            tc.verifyError(@() db.getArtifacts(Tags=q), "CarasLabDB:invalidTag");
            tc.verifyError(@() db.getArtifacts(AnyTags=["topic:x", q]), "CarasLabDB:invalidTag");
            tc.verifyError(@() db.getEvents(NotTags=q), "CarasLabDB:invalidTag");
            tc.verifyError(@() db.getSubjects(Tags="x' OR '1'='1"), "CarasLabDB:invalidTag");
            tc.verifyError(@() db.findByTags("artifact", Tags=q), "CarasLabDB:invalidTag");
            tc.verifyError(@() db.addTag("artifact", "00000000-0000-0000-0000-000000000000", q), ...
                "CarasLabDB:invalidTag");
            % Escaped properly, the database itself just finds nothing.
            tc.verifyEqual(tc.Fx.findByTagsSql("artifact", q), strings(0, 1));
            tc.verifyEqual(height(db.getArtifacts(Limit=1)), 1, "the connection is still usable");
        end
    end

    % =====================================================================
    % 5. Correction carry-forward
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function supersedeEventCarriesEventAndArtifactTags(tc)
            % Section 5: supersedeEvent copies the event's and each re-pointed
            % artifact's current tags; old rows untouched; integrity clean.
            db = tc.requireDb();
            [w, up] = tc.carryWorld("carry");
            e = w.EventId;
            [a1, a2] = deal(w.ArtifactIds(1), w.ArtifactIds(2));
            oldTags = {tc.currentTags("event", e), tc.currentTags("artifact", a1), ...
                       tc.currentTags("artifact", a2)};
            oldLog = [tc.Fx.logSnapshot("event", e); tc.Fx.logSnapshot("artifact", [a1, a2])];
            n0 = tc.Fx.counts();

            newE = db.supersedeEvent(e, Notes="corrected note");

            tc.verifyEqual(tc.currentTags("event", newE), oldTags{1});
            N = db.getArtifacts(ProducedByEventId=newE);
            tc.assertEqual(height(N), 2);
            newA = [string(N.artifact_id(string(N.supersedes) == a1)), ...
                    string(N.artifact_id(string(N.supersedes) == a2))];
            tc.verifyEqual(tc.currentTags("artifact", newA(1)), oldTags{2});
            tc.verifyEqual(tc.currentTags("artifact", newA(2)), oldTags{3});
            tc.verifyCarried("event", newE, e);
            tc.verifyCarried("artifact", newA(1), a1);
            tc.verifyCarried("artifact", newA(2), a2);

            tc.verifyEqual([tc.Fx.logSnapshot("event", e); tc.Fx.logSnapshot("artifact", [a1, a2])], ...
                oldLog, "the old rows' log is untouched");
            n1 = tc.Fx.counts();
            tc.verifyEqual(n1.tag_assignments - n0.tag_assignments, ...
                numel(oldTags{1}) + numel(oldTags{2}) + numel(oldTags{3}), "one new row per carried tag");
            tc.verifyEqual(string(LabScratchDb.column(db.getEventInputs(EventId=newE), "artifact_id")), ...
                up, "the event_input edge is carried too");
            I = tc.Fx.integrity([newE, newA]);
            tc.verifyEmpty(I, "integrity rows for the correction: " + strjoin(string(I.check_name), ", "));
        end

        function addEventWithSupersedesCarriesTags(tc)
            % Section 5: addRecordingEvent(..., Supersedes=) carries the tags.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("viaadd", 0);
            db.addTag("event", w.EventId, ["qc:pass", "topic:x", "via_add"]);
            newE = db.addRecordingEvent(OccurredAt=datetime(2026, 10, 2, 9, 0, 0, "TimeZone", "UTC"), ...
                SubjectId=w.SubjectId, SessionId=w.SessionId, Supersedes=w.EventId, NChannels=16);
            tc.verifyEqual(tc.currentTags("event", newE), tc.currentTags("event", w.EventId));
            tc.verifyCarried("event", newE, w.EventId);
            tc.verifyEmpty(tc.Fx.integrity(newE));
        end

        function supersedeArtifactAndAddArtifactCarryTags(tc)
            % Section 5: supersedeArtifact and addArtifact(..., Supersedes=).
            db = tc.requireDb();
            w = tc.Fx.makeWorld("carryart", 2);
            [a, b] = deal(w.ArtifactIds(1), w.ArtifactIds(2));
            db.addTag("artifact", a, ["stage:raw", "qc:pass", "carry_bare", "topic:x"]);
            db.addTag("artifact", b, ["stage:sorted", "topic:y"]);
            oldLog = tc.Fx.logSnapshot("artifact", [a, b]);

            newA = db.supersedeArtifact(a, Overrides=struct("format", "dat2"));
            tc.verifyEqual(tc.currentTags("artifact", newA), tc.currentTags("artifact", a));
            tc.verifyCarried("artifact", newA, a);

            B = db.getArtifacts(ArtifactId=b);
            newB = db.addArtifact(ProducedByEventId=w.EventId, StorageRootId=tc.Fx.RootId, ...
                RelativePath=string(B.relative_path), Checksum=string(B.checksum), ...
                Role="raw", Format="dat", Supersedes=b);
            tc.verifyEqual(tc.currentTags("artifact", newB), tc.currentTags("artifact", b));
            tc.verifyCarried("artifact", newB, b);

            tc.verifyEqual(tc.Fx.logSnapshot("artifact", [a, b]), oldLog);
            tc.verifyEmpty(tc.Fx.integrity([newA, newB]));
        end

        function supersedeEventIsAtomic(tc)
            % Section 5: a failure early (detail CHECK) or late (the last
            % artifact's tag carry) leaves no partial rows; AutoCommit restored.
            db = tc.requireDb();
            [w, ~] = tc.carryWorld("atomic");
            e = w.EventId;
            a2 = w.ArtifactIds(2);

            n0 = tc.Fx.counts();
            err = tc.errorOf(@() db.supersedeEvent(e, DetailOverrides=struct("n_channels", 0)));
            tc.verifySubstring(string(err.message), "recording_event_n_channels_check");
            tc.verifyEqual(tc.Fx.counts(), n0, "early failure left rows behind");
            tc.verifyEqual(string(db.Connection.AutoCommit), "on");

            % The documented concurrency gap (tagging.md section 9): two
            % sessions each add a stage value to a2 at once and both commit.
            tc.makeTwoCurrentStages(a2);
            stages = tc.currentTags("artifact", a2);
            tc.verifyEqual(stages(startsWith(stages, "stage:")), ["stage:raw"; "stage:sorted"]);
            n0 = tc.Fx.counts();
            err = tc.errorOf(@() db.supersedeEvent(e, Notes="fails while carrying a2's tags"));
            tc.verifySubstring(string(err.message), "allows one current tag");
            tc.verifyEqual(tc.Fx.counts(), n0, "late failure left rows behind");
            tc.verifyEqual(string(db.Connection.AutoCommit), "on");
            tc.verifyTrue(ismember(e, LabScratchDb.column(db.getEvents(SubjectId=w.SubjectId), "event_id")), ...
                "the event is still the active one");

            % The connection is usable for the next call.
            db.addTag("event", e, "topic:after_failure");
            tc.verifyTrue(ismember("topic:after_failure", tc.currentTags("event", e)));
        end

        function retiredTagIsSkippedWithWarning(tc)
            % Section 5: a retired tag on the predecessor is skipped with
            % CarasLabDB:retiredTagsNotCarried; integrity reports the gap.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("retcarry", 0);
            e = w.EventId;
            db.addTag("event", e, ["qc:pass", "topic:keep_rt", "topic:retire_rt"]);
            db.retireTag("topic:retire_rt");

            lastwarn("");
            newE = db.supersedeEvent(e, Notes="after the retirement");
            [msg, id] = lastwarn();
            tc.verifyEqual(string(id), "CarasLabDB:retiredTagsNotCarried");
            tc.verifySubstring(string(msg), "topic:retire_rt");
            tc.verifyEqual(tc.currentTags("event", newE), ["qc:pass"; "topic:keep_rt"]);
            I = tc.Fx.integrity(newE);
            tc.assertEqual(string(I.check_name), "tag_not_carried_forward");
            tc.verifySubstring(string(I.detail), "supersedes event " + e);
            tc.verifySubstring(string(I.detail), "topic:retire_rt");
            tc.verifyFalse(contains(string(I.detail), "keep_rt"));
        end

        function retiredTagSkippedOnArtifactCorrections(tc)
            % Section 5: the same via addArtifact(..., Supersedes=) and supersedeArtifact.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("retart", 2);
            [a, b] = deal(w.ArtifactIds(1), w.ArtifactIds(2));
            db.addTag("artifact", a, ["topic:keep_ra", "topic:retire_ra"]);
            db.addTag("artifact", b, ["topic:keep_ra", "topic:retire_ra"]);
            db.retireTag("topic:retire_ra");

            A = db.getArtifacts(ArtifactId=a);
            lastwarn("");
            newA = db.addArtifact(ProducedByEventId=w.EventId, StorageRootId=tc.Fx.RootId, ...
                RelativePath=string(A.relative_path), Checksum=string(A.checksum), Supersedes=a);
            [msg, id] = lastwarn();
            tc.verifyEqual(string(id), "CarasLabDB:retiredTagsNotCarried");
            tc.verifySubstring(string(msg), "topic:retire_ra");
            tc.verifyEqual(tc.currentTags("artifact", newA), "topic:keep_ra");

            lastwarn("");
            newB = db.supersedeArtifact(b);
            [~, id] = lastwarn();
            tc.verifyEqual(string(id), "CarasLabDB:retiredTagsNotCarried");
            tc.verifyEqual(tc.currentTags("artifact", newB), "topic:keep_ra");
            I = tc.Fx.integrity([newA, newB]);
            tc.verifyEqual(sort(string(I.subject)), sort([newA; newB]));
            tc.verifyTrue(all(string(I.check_name) == "tag_not_carried_forward"));
        end

        function transactionsAreNotNested(tc)
            % Section 5: pTransact refuses inside a caller's transaction and
            % writes nothing; plain inserts still run in it.
            db = tc.requireDb();
            admin = tc.Fx.Admin;
            w = tc.Fx.makeWorld("nested", 1);
            aid = w.ArtifactIds(1);
            c = db.Connection;
            c.AutoCommit = 'off';
            tc.addTeardown(@() TagTests.endTransaction(c));

            db.addTag("artifact", aid, "topic:in_my_txn");   % one tag: no pTransact
            n0 = tc.Fx.counts();
            calls = {
                @() db.supersedeArtifact(aid)
                @() db.addTag("artifact", aid, ["topic:m1", "topic:m2"])
                @() db.removeTag("artifact", aid, ["topic:in_my_txn", "topic:m1"])
                @() db.supersedeEvent(w.EventId)
                @() db.addRecordingEvent(OccurredAt=datetime(2026, 10, 3, "TimeZone", "UTC"), ...
                        SubjectId=w.SubjectId, SessionId=w.SessionId)};
            for i = 1:numel(calls)
                tc.verifyError(calls{i}, "CarasLabDB:transactionInProgress", func2str(calls{i}));
            end
            tc.verifyEqual(tc.Fx.counts(), n0, "nothing written");
            tc.verifyEqual(string(c.AutoCommit), "off", "the caller's transaction is still open");
            tc.verifyTrue(ismember("topic:in_my_txn", tc.currentTags("artifact", aid)));
            tc.verifyFalse(ismember("topic:in_my_txn", TagTests.tagsVia(admin, aid)), ...
                "the caller's earlier write is still uncommitted");

            newA = tc.Fx.addArtifact(w, w.EventId);     % plain addArtifact, no Supersedes
            tc.verifyEqual(height(db.getArtifacts(ArtifactId=newA)), 1);
            tc.verifyEqual(height(admin.getArtifacts(ArtifactId=newA)), 0);
            commit(c);
            c.AutoCommit = 'on';
            tc.verifyEqual(height(admin.getArtifacts(ArtifactId=newA)), 1);
            tc.verifyTrue(ismember("topic:in_my_txn", TagTests.tagsVia(admin, aid)));

            c.AutoCommit = 'off';
            gone = tc.Fx.addArtifact(w, w.EventId);
            rollback(c);
            c.AutoCommit = 'on';
            tc.verifyEqual(height(db.getArtifacts(ArtifactId=gone)), 0);
        end
    end

    % =====================================================================
    % 6. Subject rename
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function renamedSubjectKeepsItsTags(tc)
            % Section 6: lab.fn_rename_subject moves the tag log with the subject.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("rename", 0);
            old = w.SubjectId;
            new = old + "-renamed";
            db.setTag("subject", old, "cohort:a");
            db.addTag("subject", old, "topic:x");
            H0 = db.getEntityTags("subject", old, History=true);
            nLog = tc.Fx.scalar("SELECT count(*) FROM lab.tag_assignment");

            sql = "SELECT 1 AS ok FROM lab.fn_rename_subject(" + LabScratchDb.quote(old) + ", " + ...
                LabScratchDb.quote(new) + ")";
            err = tc.errorOf(@() db.runQuery(sql));
            tc.verifySubstring(string(err.message), "permission denied", "lab_rw may not rename");
            tc.verifyEqual(tc.currentTags("subject", old), ["cohort:a"; "topic:x"]);

            tc.Fx.Admin.runQuery(sql);
            tc.verifyEqual(tc.currentTags("subject", new), ["cohort:a"; "topic:x"]);
            tc.verifyEqual(tc.currentTags("subject", old), strings(0, 1));
            H1 = db.getEntityTags("subject", new, History=true);
            tc.verifyEqual(H1.assignment_id, H0.assignment_id, "same log rows, relabelled");
            tc.verifyEqual(tc.Fx.scalar("SELECT count(*) FROM lab.tag_assignment"), nLog);
            tc.verifyEqual(tc.Fx.scalar("SELECT count(*) FROM lab.tag_assignment WHERE subject_id = " + ...
                LabScratchDb.quote(old)), 0);
            tc.verifyEqual(LabScratchDb.column(db.getEvents(SubjectId=new), "event_id"), w.EventId);
            tc.verifyEqual(sort(db.findByTags("subject", Tags=["cohort:a", "topic:x"])), ...
                sort(tc.Fx.findByTagsSql("subject", ["cohort:a", "topic:x"])));
            tc.verifyTrue(ismember(new, db.findByTags("subject", Tags="cohort:a")));
        end
    end

    % =====================================================================
    % 7. Argument validation (defaults are validated eagerly from R2024b)
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function newMethodsWithRequiredArgumentsOnly(tc)
            % Section 7: every new method with only its required arguments, and
            % each optional empty/integer default omitted and supplied.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("req", 1);
            aid = w.ArtifactIds(1);
            tc.verifyNotEmpty(db.getTagNamespaces());
            tc.verifyNotEmpty(db.getTags());
            tc.verifyEqual(db.addTagNamespace(Namespace="mt_req", Mutability="mutable", ...
                Cardinality="multi", AppliesTo="artifact"), "mt_req");
            tc.verifyEqual(db.registerTag("mt_req:v"), "mt_req:v");
            tc.verifySize(db.addTag("artifact", aid, "mt_req:v"), [1 1]);
            tc.verifySize(db.removeTag("artifact", aid, "mt_req:v"), [1 1]);
            [id, changed] = db.setTag("artifact", aid, "stage:raw");
            tc.verifyTrue(isfinite(id) && changed);
            tc.verifyEqual(height(db.getEntityTags("artifact", aid)), 1);
            tc.verifyEqual(sort(db.findByTags("artifact")), sort(tc.Fx.findByTagsSql("artifact")), ...
                "no tokens: every active artifact");
            db.retireTag("mt_req:v");
            tc.verifyWarning(@() db.updateTagNamespace("mt_req"), "CarasLabDB:nothingToUpdate");
            for g = {@() db.getEvents(), @() db.getArtifacts(), @() db.getSubjects(), ...
                     @() db.getSessions(), @() db.getProjects()}
                tc.verifyClass(g{1}(), "table", func2str(g{1}));
            end

            db.updateTagNamespace("mt_req", OpenVocabulary=false);
            tc.verifyFalse(logical(db.getTagNamespaces(Namespace="mt_req").open_vocabulary));
            db.updateTagNamespace("mt_req", OpenVocabulary=true, AppliesTo=["artifact", "event"]);
            tc.verifyEqual(db.getTagNamespaces(Namespace="mt_req").applies_to, "event,artifact");
            tc.verifyTrue(ismember(w.SessionId, ...
                LabScratchDb.column(db.getSessions(StorageRootId=tc.Fx.RootId), "session_id")));
            tc.verifyEqual(height(db.getEvents(Limit=1)), 1);
            tc.verifyEqual(height(db.getArtifacts(Limit=1, Tags="stage:raw")), 1);
            tc.verifyEqual(sort(db.findByTags("artifact", ActiveOnly=false)), ...
                sort(tc.Fx.findByTagsSql("artifact", [], [], [], false)));
            db.addTagNamespace(Namespace="mt_req_closed", Mutability="mutable", Cardinality="single", ...
                AppliesTo="event", OpenVocabulary=false);
            tc.verifyFalse(logical(db.getTagNamespaces(Namespace="mt_req_closed").open_vocabulary));
            e1 = db.addRecordingEvent(OccurredAt=datetime(2026, 10, 4, "TimeZone", "UTC"), ...
                SubjectId=w.SubjectId, SessionId=w.SessionId);
            e2 = db.addRecordingEvent(OccurredAt=datetime(2026, 10, 4, "TimeZone", "UTC"), ...
                SubjectId=w.SubjectId, SessionId=w.SessionId, NChannels=16);
            D = db.getEventDetail(EventId=e2);
            tc.verifyEqual(double(D.n_channels), 16);
            tc.verifyTrue(ismissing(string(db.getEventDetail(EventId=e1).n_channels)) || ...
                isnan(double(db.getEventDetail(EventId=e1).n_channels)));
            tc.verifyEqual(height(db.getTags(Namespace="mt_req", IncludeRetired=true)), 1);
            tc.verifyEqual(height(db.getEntityTags("artifact", aid, History=true)), 3);
        end
    end

    methods (Test, TestTags = {'NoDatabase'})
        function defaultsPassValidationOnEveryRelease(tc)
            % Section 7, without a server (runs on R2024b too): no method's
            % default values fail argument validation.
            tc.applyFixture(matlab.unittest.fixtures.SuppressedWarningsFixture( ...
                ["CarasLabDB:nothingToUpdate", "CarasLabDB:retiredTagsNotCarried"]));
            [db, ~] = TagTests.recordingDb();
            id = "00000000-0000-0000-0000-000000000002";
            t = datetime(2026, 10, 1, "TimeZone", "UTC");
            calls = {
                @() db.getTagNamespaces()
                @() db.getTags()
                @() db.updateTagNamespace("topic")
                @() db.updateTagNamespace("topic", OpenVocabulary=true)
                @() db.updateTagNamespace("topic", AppliesTo="event")
                @() db.retireTag("topic:a")
                @() db.addTagNamespace(Namespace="mt_a", Mutability="mutable", Cardinality="multi", AppliesTo="event")
                @() db.addTagNamespace(Namespace="mt_a", Mutability="mutable", Cardinality="multi", ...
                        AppliesTo="event", OpenVocabulary=false)
                @() db.registerTag("topic:a")
                @() db.addTag("event", id, "topic:a")
                @() db.removeTag("event", id, "topic:a")
                @() db.setTag("artifact", id, "stage:raw")
                @() db.getEntityTags("event", id)
                @() db.findByTags("event")
                @() db.findByTags("event", ActiveOnly=false)
                @() db.getEvents()
                @() db.getEvents(Limit=3)
                @() db.getArtifacts()
                @() db.getSubjects()
                @() db.getSessions()
                @() db.getSessions(StorageRootId=1)
                @() db.getProjects()
                @() db.supersedeEvent(id)
                @() db.supersedeArtifact(id)
                @() db.addArtifact(ProducedByEventId=id, StorageRootId=1, RelativePath="a/b.dat", ...
                        Checksum=LabScratchDb.checksum(1))
                @() db.addRecordingEvent(OccurredAt=t)
                @() db.addRecordingEvent(OccurredAt=t, NChannels=16)};
            for i = 1:numel(calls)
                try
                    calls{i}();
                catch ME
                    % Only argument validation matters here; the fake
                    % connection's empty results make later steps fail.
                    isValidation = startsWith(string(ME.identifier), ["MATLAB:validators:", "MATLAB:validation:"]) ...
                        || contains(ME.message, "default value");
                    tc.verifyFalse(isValidation, func2str(calls{i}) + ": " + ME.message);
                end
            end
        end
    end

    % =====================================================================
    % 8. Demo script
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function demoScriptRunsEndToEnd(tc)
            % Section 8: examples/carasLabDB_demo.m with only its connection
            % settings changed; its tagging step prints the expected results.
            tc.requireDb();
            src = string(fileread(fullfile(tc.Fx.RepoRoot, "examples", "carasLabDB_demo.m")));
            s = tc.Fx.connectionSettings();
            demo = src;
            demo = regexprep(demo, 'Username(\s*)=\s*"[^"]*"', "Username$1= """ + s.Username + """", "once");
            demo = regexprep(demo, 'Password(\s*)=\s*"[^"]*"', "Password$1= """ + s.Password + """", "once");
            demo = regexprep(demo, 'Server(\s*)=\s*"[^"]*"', "Server$1= """ + s.Server + """", "once");
            demo = regexprep(demo, 'Port(\s*)=\s*\d+', "Port$1= " + s.Port, "once");
            demo = regexprep(demo, 'DatabaseName(\s*)=\s*"[^"]*"', "DatabaseName$1= """ + s.DatabaseName + """", "once");
            demo = regexprep(demo, 'PersonEmail(\s*)=\s*"[^"]*"', "PersonEmail$1= """ + s.PersonEmail + """", "once");
            changed = splitlines(demo) ~= splitlines(src);
            tc.assertEqual(nnz(changed), 6, "only the six connection settings are adapted");

            folder = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            file = fullfile(folder, "carasLabDB_demo_mtest.m");
            fid = fopen(file, "w", "n", "UTF-8");
            fprintf(fid, "%s", demo);
            fclose(fid);

            [out, v] = local_runScript(file);
            tc.log(1, "Demo output:" + newline + out);
            tc.verifyFalse(contains(out, "Warning"), "the demo printed a warning");

            db = tc.Fx.Db;
            raw = v.rawId;
            tc.verifyEqual(tc.currentTags("artifact", raw), ["stage:preprocessed"; "tag:pilot"; "topic:tonotopy"]);
            for t = ["stage:preprocessed", "pilot", "topic:tonotopy"]
                tc.verifySubstring(out, t);
            end
            H = db.getEntityTags("artifact", raw, History=true);
            tc.verifyEqual(string(H.op)', ["add", "add", "add", "remove", "add"]);
            tc.verifyEqual(string(H.tag)', ["stage:raw", "topic:tonotopy", "tag:pilot", ...
                "stage:raw", "stage:preprocessed"]);
            tc.verifyEqual(string(H.note(2:3))', ["first penetration", "first penetration"]);
            tc.verifyEqual(tc.currentTags("subject", "G-0421"), "cohort:a");

            nPre = numel(tc.Fx.findByTagsSql("artifact", "stage:preprocessed", [], "qc:fail"));
            inSession = intersect(tc.Fx.findByTagsSql("artifact", "stage:preprocessed"), ...
                LabScratchDb.column(db.getArtifacts(SessionId=v.sid), "artifact_id"));
            nTopic = numel(tc.Fx.findByTagsSql("artifact", "topic:*"));
            tc.verifySubstring(out, sprintf("preprocessed artifacts: %d (%d in this session); with a topic: %d", ...
                nPre, numel(inSession), nTopic));
            tc.verifyEqual(numel(inSession), 1);
            tc.verifySubstring(out, "weight event " + v.wEid + " superseded by " + v.newWEid);
            tc.verifyEqual(tc.currentTags("event", v.newWEid), "qc:pass");
            tc.verifyCarried("event", v.newWEid, v.wEid);
            tc.verifySubstring(out, "active events: ");
        end
    end

    % =====================================================================
    % Helpers
    % =====================================================================
    methods (Access = private)
        function db = requireDb(tc)
            tc.assumeTrue(tc.Fx.Available, tc.Fx.Reason);
            db = tc.Fx.Db;
        end

        function tags = currentTags(tc, kind, id)
            %CURRENTTAGS The entity's current tags, sorted, as a string column.
            tags = sort(LabScratchDb.column(tc.Fx.Db.getEntityTags(kind, id), "tag"));
        end

        function err = errorOf(tc, fn)
            %ERROROF The MException FN throws; a verification failure if none.
            err = [];
            try
                fn();
            catch err
            end
            if isempty(err)
                tc.verifyFail("expected an error from " + func2str(fn) + ", but it succeeded");
                err = MException("TagTests:noError", "(no error)");
            end
        end

        function verifyNamespace(tc, ns, mutability, cardinality, appliesTo)
            R = tc.Fx.Db.getTagNamespaces(Namespace=ns);
            tc.verifyEqual([string(R.mutability), string(R.cardinality), R.applies_to], ...
                [mutability, cardinality, appliesTo], ns);
        end

        function verifyCarried(tc, kind, newId, oldId)
            %VERIFYCARRIED NEWID's log is one 'add' per carried tag, noted and attributed.
            H = tc.Fx.Db.getEntityTags(kind, newId, History=true);
            tc.verifyNotEmpty(H, kind + " " + newId + " has no tags");
            tc.verifyTrue(all(string(H.op) == "add"), kind);
            tc.verifyTrue(all(string(H.note) == "carried forward from " + oldId), kind);
            tc.verifyTrue(all(string(H.applied_by) == tc.Fx.Db.CurrentPersonId), kind);
        end

        function tf = databaseRejectsTag(tc, tag)
            %DATABASEREJECTSTAG Whether INSERT INTO lab.tag refuses TAG (rolled back either way).
            c = tc.Fx.Admin.Connection;
            c.AutoCommit = 'off';
            restore = onCleanup(@() TagTests.endTransaction(c));
            try
                execute(c, "INSERT INTO lab.tag (tag) VALUES (" + CarasLabDB.sqlLiteral(tag) + ")");
                tf = false;
            catch
                tf = true;
            end
        end

        function [w, upstream] = carryWorld(tc, prefix)
            %CARRYWORLD Event with two tagged artifacts and one tagged input.
            db = tc.Fx.Db;
            w = tc.Fx.makeWorld(prefix, 2);
            u = tc.Fx.addEvent(w);
            upstream = tc.Fx.addArtifact(w, u);
            db.addEventInput(EventId=w.EventId, ArtifactId=upstream, Role="raw");
            db.addTag("event", w.EventId, ["qc:pass", "carry_bare", "topic:x"]);
            db.addTag("artifact", w.ArtifactIds(1), ["stage:raw", "qc:pass", "carry_bare", "topic:x"]);
            db.addTag("artifact", w.ArtifactIds(2), "topic:x");
        end

        function makeTwoCurrentStages(tc, aid)
            %MAKETWOCURRENTSTAGES Two current stage tags on AID, as two racing writers would leave.
            admin = tc.Fx.Admin;
            c = admin.Connection;
            c.AutoCommit = 'off';
            restore = onCleanup(@() TagTests.endTransaction(c));
            ins = "INSERT INTO lab.tag_assignment (entity_kind, artifact_id, tag, op, note) " + ...
                "VALUES ('artifact', " + LabScratchDb.quote(aid) + ", ";
            admin.runCommand(ins + "'stage:raw', 'add', 'concurrent writer 1')");
            tc.Fx.Db.runCommand(ins + "'stage:sorted', 'add', 'concurrent writer 2')");
            commit(c);
        end

        function f = filterWorld(tc)
            %FILTERWORLD 6 artifacts, 4 events, 2 subjects/sessions/projects, tagged to overlap.
            fx = tc.Fx;
            db = fx.Db;
            w1 = fx.makeWorld("filt", 3);
            w2 = fx.makeWorld("filt", 3);
            f.A = [w1.ArtifactIds, w2.ArtifactIds];
            f.E = [w1.EventId, fx.addEvent(w1), w2.EventId, fx.addEvent(w2)];
            f.S = [w1.SubjectId, w2.SubjectId];
            f.SS = [w1.SessionId, w2.SessionId];
            f.P = [w1.ProjectId, w2.ProjectId];
            db.addTag("artifact", f.A(1), ["stage:raw", "topic:x", "qc:pass", "pilot"]);
            db.addTag("artifact", f.A(2), ["stage:raw", "topic:y", "qc:fail"]);
            db.addTag("artifact", f.A(3), ["stage:sorted", "topic:x"]);
            db.addTag("artifact", f.A(4), ["stage:raw", "topic:x", "qc:fail"]);
            db.addTag("artifact", f.A(6), ["stage:sorted", "qc:pass", "pilot"]);
            db.addTag("event", f.E(1), ["qc:pass", "topic:x"]);
            db.addTag("event", f.E(2), "qc:fail");
            db.addTag("event", f.E(3), "pilot");
            db.addTag("subject", f.S(1), ["cohort:a", "topic:x"]);
            db.addTag("subject", f.S(2), "cohort:b");
            db.addTag("session", f.SS(1), "qc:pass");
            db.addTag("project", f.P(1), "topic:x");
            db.addTag("project", f.P(2), "pilot");
        end

        function checkFilter(tc, kind, args, expected, scope, label)
            %CHECKFILTER Getter rows and findByTags ids vs lab.fn_find_by_tags.
            %   ARGS holds getter Name=Value arguments: Tags, AnyTags, NotTags,
            %   ActiveOnly and optionally SubjectId. EXPECTED is the subset of
            %   SCOPE (this test's rows) that must match.
            db = tc.Fx.Db;
            idCol = kind + "_id";
            getters = struct( ...
                "artifact", @(varargin) db.getArtifacts(varargin{:}), ...
                "event",    @(varargin) db.getEvents(varargin{:}), ...
                "subject",  @(varargin) db.getSubjects(varargin{:}), ...
                "session",  @(varargin) db.getSessions(varargin{:}), ...
                "project",  @(varargin) db.getProjects(varargin{:}));
            c = namedargs2cell(args);
            got = LabScratchDb.column(getters.(kind)(c{:}), idCol);

            pick = @(n) TagTests.field(args, n, strings(1, 0));
            active = TagTests.field(args, "ActiveOnly", true);
            want = tc.Fx.findByTagsSql(kind, pick("Tags"), pick("AnyTags"), pick("NotTags"), active);
            if isfield(args, "SubjectId")
                owned = LabScratchDb.column(db.runQuery("SELECT " + idCol + "::text AS id FROM lab." + ...
                    kind + " WHERE subject_id = " + LabScratchDb.quote(args.SubjectId)), "id");
                want = intersect(want, owned);
            else
                ids = db.findByTags(kind, Tags=pick("Tags"), AnyTags=pick("AnyTags"), ...
                    NotTags=pick("NotTags"), ActiveOnly=active);
                tc.verifyEqual(sort(ids), sort(want), label + ": findByTags vs lab.fn_find_by_tags");
            end
            tc.verifyEqual(sort(got), sort(want), label + ": getter vs lab.fn_find_by_tags");
            mine = intersect(got, reshape(scope, [], 1));
            tc.verifyEqual(sort(mine), sort(reshape(string(expected), [], 1)), label + ": this test's rows");
        end
    end

    methods (Static, Access = private)
        function x = malformedTags()
            x = ["stage:raw data", "stage:", "a:b:c", "stage:raw!", "1ns:x", ...
                 "topic:" + TagTests.as(65), "", ":x", "topic:-x", "topic:o'brien", ...
                 "Probe Site:x", "n" + TagTests.as(32) + ":x", "stage :raw", "topic:a" + char(9)];
        end

        function s = as(n)
            s = string(repmat('a', 1, n));
        end

        function v = field(s, name, default)
            if isfield(s, name)
                v = s.(name);
            else
                v = default;
            end
        end

        function [db, conn] = recordingDb()
            conn = RecordingConnection();
            db = CarasLabDB(Connection=conn, PersonId="00000000-0000-0000-0000-000000000001");
            conn.clearLog();
        end

        function tags = tagsVia(other, aid)
            %TAGSVIA Current tags of artifact AID as another session sees them.
            tags = LabScratchDb.column(other.getEntityTags("artifact", aid), "tag");
        end

        function endTransaction(c)
            try
                rollback(c);
            catch
            end
            c.AutoCommit = 'on';
        end
    end
end

% =========================================================================
function [out, vars] = local_runScript(file__) %#ok<INUSD> (used inside evalc)
    %LOCAL_RUNSCRIPT Run a script, returning its printed output and its variables.
    out = string(evalc("run(file__)"));
    names = setdiff(string(who), ["file__", "out"]);
    vars = struct();
    for i = 1:numel(names)
        vars.(names(i)) = eval(names(i));
    end
end
