require 'test_helper'

class LevelsWithinLevelsTest < ActiveSupport::TestCase
  test 'cannot delete levels that other levels reference as children' do
    child = create(:multi, parent_levels: [create(:level)])

    refute child.destroy

    assert_equal ["Cannot delete record because dependent parent levels exist"],
      child.errors.full_messages
    refute child.destroyed?
  end

  test 'can delete levels that other levels reference as parents' do
    child = create(:free_response)
    parent = create(:level, child_levels: [child])

    assert parent.destroy

    assert parent.destroyed?
    refute child.destroyed?
  end

  test 'deleting a parent level will also remove associations' do
    child = create(:multi)
    parent = create(:level, child_levels: [child])
    assert child.levels_parent_levels.present?

    assert parent.destroy

    child.reload
    assert parent.destroyed?
    refute child.destroyed?
    assert child.levels_parent_levels.empty?
  end

  test 'parent levels and child levels' do
    parent = create :level
    child = create :level
    parent.child_levels << child
    assert_equal [parent], child.parent_levels

    # cannot add the same child a second time
    assert_raises ActiveRecord::RecordInvalid do
      parent.child_levels << child
    end

    # cannot add the same parent a second time
    assert_raises ActiveRecord::RecordInvalid do
      child.parent_levels << parent
    end
  end

  test 'scoped parent/child relationships' do
    parent = create :level

    contained = create :free_response
    ParentLevelsChildLevel.create(
      parent_level: parent,
      child_level: contained,
      kind: ParentLevelsChildLevel::CONTAINED
    )

    project_template = create :level
    ParentLevelsChildLevel.create(
      parent_level: parent,
      child_level: project_template,
      kind: ParentLevelsChildLevel::PROJECT_TEMPLATE
    )

    sublevel = create :level
    ParentLevelsChildLevel.create(
      parent_level: parent,
      child_level: sublevel,
      kind: ParentLevelsChildLevel::SUBLEVEL
    )

    assert_equal [contained, project_template, sublevel], parent.child_levels
    assert_equal [contained], parent.child_levels.contained
    assert_equal [project_template], parent.child_levels.project_template
    assert_equal [sublevel], parent.child_levels.sublevel
  end

  test 'child levels are in order of position' do
    parent = create :level
    child3 = create :level
    child2 = create :level
    child1 = create :level
    ParentLevelsChildLevel.find_or_create_by!(
      parent_level: parent,
      child_level: child3,
      position: 3
    )
    ParentLevelsChildLevel.find_or_create_by!(
      parent_level: parent,
      child_level: child1,
      position: 1
    )
    ParentLevelsChildLevel.find_or_create_by!(
      parent_level: parent,
      child_level: child2,
      position: 2
    )
    assert_equal [child1, child2, child3], parent.child_levels
  end

  test 'setup contained levels' do
    level = create :level
    assert_equal [], level.child_levels.contained

    # can add
    first_contained = create :multi
    level.update!(contained_level_names: [first_contained.name])
    assert_equal [first_contained], level.child_levels.contained

    # can reorder
    second_contained = create :free_response
    level.update!(contained_level_names: [first_contained.name, second_contained.name])
    assert_equal [first_contained, second_contained], level.child_levels.contained
    level.update!(contained_level_names: [second_contained.name, first_contained.name])
    assert_equal [second_contained, first_contained], level.child_levels.contained

    # can remove
    level.update!(contained_level_names: [])
    assert_equal [], level.reload.child_levels.contained

    # cannot add contained levels of other types
    bogus_contained = create :match
    refute level.update(contained_level_names: [bogus_contained.name])
    assert_includes level.errors.full_messages.first, 'cannot add contained level of type Match'
  end

  test 'clone_child_levels clones child levels' do
    parent = create :level
    child = create :free_response, name: 'child_level'
    assert ParentLevelsChildLevel.create(parent_level: parent, child_level: child)
    Level.clone_child_levels(parent, '_test_clone')
    assert_equal 'child_level_test_clone', parent.reload.child_levels.first.name
  end

  test 'clone_child_levels returns update params' do
    parent = create :level
    child = create :free_response, name: 'child_level'
    assert ParentLevelsChildLevel.create(
      parent_level: parent,
      child_level: child,
      kind: ParentLevelsChildLevel::CONTAINED
    )
    result = Level.clone_child_levels(parent, '_test_clone')
    expected = {contained_level_names: ['child_level_test_clone']}
    assert_equal expected, result
  end

  test 'project template level' do
    template_level = Blockly.create(name: 'project_template')
    template_level.start_blocks = '<xml/>'
    template_level.save!

    assert_nil template_level.project_template_level
    assert_equal '<xml/>', template_level.start_blocks

    real_level1 = Blockly.create(name: 'level 1')
    real_level1.project_template_level_name = 'project_template'
    real_level1.save!

    assert_equal template_level, real_level1.project_template_level
  end

  test 'can unset project template level' do
    template_level = create(:level)
    real_level = create(:level, project_template_level_name: template_level.name)
    assert_equal template_level, real_level.project_template_level

    real_level.update!(project_template_level_name: nil)
    assert_nil real_level.project_template_level
  end

  test 'level cannot be its own project template level' do
    level = create :level
    refute level.update(project_template_level_name: level.name)
    assert_includes level.errors.full_messages.first, 'level cannot be its own project template level'
  end

  test 'template level type must match level type' do
    applab = create :applab
    gamelab = create :gamelab

    refute applab.update(project_template_level_name: gamelab.name)
    assert_includes applab.errors.full_messages.first, 'template level type Gamelab does not match level type Applab'
  end

  test 'project template level cannot have its own project template level' do
    project_backed_level = create :level, name: 'project backed'
    template_level = create :level
    project_backed_level.project_template_level_name = template_level.name
    project_backed_level.save!

    parent_level = create :level
    refute parent_level.update(project_template_level_name: project_backed_level.name)
    assert_includes parent_level.errors.full_messages.first, 'the project template level you have selected already has its own project template level'

    template_template_level = create :level
    refute template_level.update(project_template_level_name: template_template_level.name)
    assert_includes template_level.errors.full_messages.first, 'this level is already a project template level of another level'
  end
end
